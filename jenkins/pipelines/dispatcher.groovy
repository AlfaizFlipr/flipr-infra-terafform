pipeline {
  agent {
    kubernetes {
      defaultContainer 'tools'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: default
  containers:
  - name: tools
    image: alpine:3.22
    command: ["sleep"]
    args: ["99d"]
'''
    }
  }
  options {
    ansiColor('xterm')
    disableConcurrentBuilds()
    timeout(time: 20, unit: 'MINUTES')
  }
  triggers { cron('@@POLL_SCHEDULE@@') }
  environment {
    GITHUB_TOKEN = credentials('fliprlab-github-token')
    GITHUB_ORG = '@@GITHUB_ORG@@'
    REPOSITORIES = '@@REPOSITORIES@@'
    DEPLOY_NAMESPACE = '@@DEPLOY_NAMESPACE@@'
    INTERNAL_JENKINS_URL = 'http://jenkins.jenkins.svc.cluster.local:8080'
  }
  stages {
    stage('Poll open pull requests') {
      steps {
        sh '''
          set +x
          set -eu
          apk add --no-cache curl jq kubectl
          github_get() {
            curl --fail --silent --show-error -H "Accept: application/vnd.github+json" \
              -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
              "https://api.github.com$1"
          }
          trigger_job() {
            repository=$1; pipeline_name=$2; branch_job=$3; shift 3
            cookie_jar=$(mktemp)
            crumb=$(curl --fail --silent --show-error -c "$cookie_jar" "${INTERNAL_JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
            curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" "$@" \
              "${INTERNAL_JENKINS_URL}/job/FLIPRLABS/job/${repository}/job/${pipeline_name}/job/${branch_job}/buildWithParameters"
            rm -f "$cookie_jar"
          }
          ensure_branch_job() {
            repository=$1; pipeline_name=$2; branch_job=$3
            base="${INTERNAL_JENKINS_URL}/job/FLIPRLABS/job/${repository}/job/${pipeline_name}"
            cookie_jar=$(mktemp)
            crumb=$(curl --fail --silent --show-error -c "$cookie_jar" "${INTERNAL_JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
            curl --fail --silent --show-error "$base/job/_template/config.xml" -o branch-config.xml
            if ! curl --fail --silent "$base/job/${branch_job}/api/json" >/dev/null 2>&1; then
              curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" \
                -H 'Content-Type: application/xml' --data-binary '@branch-config.xml' \
                "$base/createItem?name=${branch_job}"
            fi
            # Keep existing managed branch jobs synchronized with the template.
            curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" \
              -H 'Content-Type: application/xml' --data-binary '@branch-config.xml' \
              "$base/job/${branch_job}/config.xml"
            curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" \
              "$base/job/${branch_job}/enable"
            rm -f "$cookie_jar"
          }
          if kubectl -n "$DEPLOY_NAMESPACE" get configmap flipr-ci-dispatcher-state -o jsonpath='{.data.state\\.json}' > state.json 2>/dev/null; then
            existing_state=true
          else
            existing_state=false
            printf '{}\n' > state.json
          fi
          old_ifs=$IFS
          IFS=,
          for repository in $REPOSITORIES; do
            IFS=$old_ifs
            pulls=$(github_get "/repos/${GITHUB_ORG}/${repository}/pulls?state=open&per_page=100")
            printf '%s' "$pulls" | jq -r '.[] | [.number,.head.sha,.head.ref,.base.ref] | @base64' | while IFS= read -r encoded; do
              pull=$(printf '%s' "$encoded" | base64 -d)
              number=$(printf '%s' "$pull" | jq -r '.[0]')
              sha=$(printf '%s' "$pull" | jq -r '.[1]')
              head_ref=$(printf '%s' "$pull" | jq -r '.[2]')
              base_ref=$(printf '%s' "$pull" | jq -r '.[3]')
              branch_job=$(printf '%s' "$head_ref" | sed 's/[^A-Za-z0-9._-]/-/g')
              ensure_branch_job "$repository" pull-request-checker "$branch_job"
              ensure_branch_job "$repository" pull-request-deploy "$branch_job"
              check_key="check:${repository}:${number}"
              if [ "$(jq -r --arg key "$check_key" '.[$key] // ""' state.json)" != "$sha" ]; then
                trigger_job "$repository" pull-request-checker "$branch_job" --data-urlencode "REPOSITORY=$repository" --data-urlencode "PR_NUMBER=$number" \
                  --data-urlencode "HEAD_SHA=$sha" --data-urlencode "HEAD_REF=$head_ref" --data-urlencode "BASE_REF=$base_ref"
                jq --arg key "$check_key" --arg value "$sha" '.[$key]=$value' state.json > state.next
                mv state.next state.json
              fi
              comments=$(github_get "/repos/${GITHUB_ORG}/${repository}/issues/${number}/comments?per_page=100")
              printf '%s' "$comments" | jq -r '.[] | select((.body | gsub("^\\s+|\\s+$"; "")) == "/deploy") | .id' | while IFS= read -r comment_id; do
                deploy_key="deploy:${repository}:${comment_id}"
                if [ "$existing_state" = true ] && [ "$(jq -r --arg key "$deploy_key" '.[$key] // ""' state.json)" = "" ]; then
                  trigger_job "$repository" pull-request-deploy "$branch_job" --data-urlencode "REPOSITORY=$repository" --data-urlencode "PR_NUMBER=$number" \
                    --data-urlencode "HEAD_SHA=$sha" --data-urlencode "HEAD_REF=$head_ref" --data-urlencode "BASE_REF=$base_ref" \
                    --data-urlencode "COMMENT_ID=$comment_id"
                fi
                jq --arg key "$deploy_key" --arg value "$sha" '.[$key]=$value' state.json > state.next
                mv state.next state.json
              done
            done
            IFS=,
          done
          IFS=$old_ifs
          kubectl -n "$DEPLOY_NAMESPACE" create configmap flipr-ci-dispatcher-state \
            --from-file=state.json --dry-run=client -o yaml | kubectl apply -f -
        '''
      }
    }
  }
}
