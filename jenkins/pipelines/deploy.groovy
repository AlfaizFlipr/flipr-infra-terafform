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
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.2-debug
    command: ["/busybox/sh", "-c"]
    args: ["sleep 99d"]
  - name: kubectl
    image: bitnami/kubectl:1.36
    command: ["sleep"]
    args: ["99d"]
'''
    }
  }
  options {
    ansiColor('xterm')
    disableConcurrentBuilds(abortPrevious: true)
    timeout(time: 30, unit: 'MINUTES')
  }
  parameters {
    string(name: 'REPOSITORY', defaultValue: '', description: 'GitHub repository name')
    string(name: 'PR_NUMBER', defaultValue: '', description: 'GitHub pull request number')
    string(name: 'HEAD_SHA', defaultValue: '', description: 'Exact PR head commit')
    string(name: 'HEAD_REF', defaultValue: '', description: 'PR source branch')
    string(name: 'BASE_REF', defaultValue: '', description: 'PR target branch')
    string(name: 'COMMENT_ID', defaultValue: '', description: 'GitHub /deploy comment ID (idempotency key)')
  }
  environment {
    GITHUB_ORG = '@@GITHUB_ORG@@'
    REGISTRY = '@@REGISTRY@@'
    DEPLOY_NAMESPACE = '@@DEPLOY_NAMESPACE@@'
    GITHUB_TOKEN = credentials('fliprlab-github-token')
  }
  stages {
    stage('Validate deploy request') {
      steps {
        script {
          if (!params.REPOSITORY.trim() || !(params.PR_NUMBER ==~ /[0-9]+/) || !(params.HEAD_SHA ==~ /[0-9a-f]{40}/) || !params.COMMENT_ID.trim()) {
            error('A valid dispatcher-generated REPOSITORY, PR_NUMBER, HEAD_SHA and COMMENT_ID are required.')
          }
        }
      }
    }
    stage('Checkout PR commit') {
      steps {
        container('tools') {
          sh '''
            set +x
            set -eu
            apk add --no-cache git
            git config --global --add safe.directory "$WORKSPACE"
            git init .
            git remote add origin "https://github.com/${GITHUB_ORG}/${REPOSITORY}.git"
            if [ -n "${GITHUB_TOKEN:-}" ]; then
              git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${REPOSITORY}.git"
            fi
            git fetch --depth=1 origin "${HEAD_SHA}"
            git checkout --detach FETCH_HEAD
          '''
        }
      }
    }
    stage('Prepare image') {
      steps {
        container('tools') {
          sh '''
            set +x
            set -eu
            # Test-only mode: never execute a Dockerfile supplied by a PR.
            # The checked-out project remains read-only input for CI checks.
            mkdir -p .jenkins-test-image
            printf '%s\n' 'FROM nginx:1.29-alpine' \
              'COPY deployment.txt /usr/share/nginx/html/index.html' > .jenkins-test-image/Dockerfile
            printf 'Test deployment for %s/%s PR #%s commit %s\n' \
              "$GITHUB_ORG" "$REPOSITORY" "$PR_NUMBER" "$HEAD_SHA" > .jenkins-test-image/deployment.txt
          '''
        }
      }
    }
    stage('Build and push') {
      steps {
        container('kaniko') {
          sh '''
            set +x
            set -eu
            IMAGE="${REGISTRY}/${REPOSITORY}:pr-${PR_NUMBER}-${HEAD_SHA%%????????????????????????????????}"
            /kaniko/executor --context "$WORKSPACE/.jenkins-test-image" \
              --dockerfile "$WORKSPACE/.jenkins-test-image/Dockerfile" \
              --destination "$IMAGE" --insecure --skip-tls-verify
            printf '%s' "$IMAGE" > .jenkins-image
          '''
        }
      }
    }
    stage('Dummy deploy') {
      steps {
        container('kubectl') {
          sh '''
            set +x
            set -eu
            APP=$(printf '%s-pr-%s' "$REPOSITORY" "$PR_NUMBER" | tr '_' '-' | cut -c1-63)
            IMAGE=$(cat .jenkins-image)
            # K3s is not yet configured to pull from this insecure HTTP registry.
            # Deploy a harmless placeholder and retain the built image as metadata.
            kubectl -n "$DEPLOY_NAMESPACE" create deployment "$APP" --image=nginx:1.29-alpine --dry-run=client -o yaml | kubectl apply -f -
            kubectl -n "$DEPLOY_NAMESPACE" set env deployment/"$APP" FLIPR_PR="$PR_NUMBER" FLIPR_COMMIT="$HEAD_SHA"
            kubectl -n "$DEPLOY_NAMESPACE" annotate deployment/"$APP" fliprlabs.io/built-image="$IMAGE" --overwrite
            kubectl -n "$DEPLOY_NAMESPACE" rollout status deployment/"$APP" --timeout=5m
          '''
        }
      }
    }
  }
  post {
    success { echo "Built and dummy-deployed PR #${params.PR_NUMBER}." }
  }
}
