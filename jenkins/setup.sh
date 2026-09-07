#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${CONFIG_FILE:-"$SCRIPT_DIR/config.env"}
REPOSITORY_FILE=${REPOSITORY_FILE:-"$SCRIPT_DIR/repositories.txt"}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

: "${JENKINS_URL:=http://127.0.0.1:18080}"
: "${GITHUB_ORG:=fliprlab}"
: "${REGISTRY:=docker-registry.registry.svc.cluster.local:5000}"
: "${DEPLOY_NAMESPACE:=ci-preview}"
: "${POLL_SCHEDULE:=H/5 * * * *}"

for command in curl sed awk kubectl; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

jenkins_post() {
  local endpoint=$1
  local content_type=$2
  local body_file=$3
  local crumb
  local cookie_jar
  cookie_jar=$(mktemp)
  crumb=$(curl --fail --silent --show-error -c "$cookie_jar" "${JENKINS_URL%/}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
  curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" -H "Content-Type: $content_type" \
    --data-binary "@$body_file" "${JENKINS_URL%/}/$endpoint"
  rm -f "$cookie_jar"
}

render_pipeline() {
  local source=$1
  local destination=$2
  local repository=${3:-}
  local repositories=${4:-}
  sed -e "s|@@GITHUB_ORG@@|$GITHUB_ORG|g" \
      -e "s|@@REPOSITORY@@|$repository|g" \
      -e "s|@@REPOSITORIES@@|$repositories|g" \
      -e "s|@@REGISTRY@@|$REGISTRY|g" \
      -e "s|@@DEPLOY_NAMESPACE@@|$DEPLOY_NAMESPACE|g" \
      -e "s|@@POLL_SCHEDULE@@|$POLL_SCHEDULE|g" \
      "$source" > "$destination"
}

create_folder() {
  local name=$1
  local encoded_name=${name// /%20}
  local config
  local item_status
  config=$(mktemp)
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder">' \
    '  <actions/>' \
    "  <description>Flipr Labs CI/CD pipelines for $name</description>" \
    '  <properties/>' \
    '  <folderViews class="com.cloudbees.hudson.plugins.folder.views.DefaultFolderViewHolder">' \
    '    <views><hudson.model.AllView><owner class="com.cloudbees.hudson.plugins.folder.Folder" reference="../../../.."/><name>All</name><filterExecutors>false</filterExecutors><filterQueue>false</filterQueue><properties class="hudson.model.View$PropertyList"/></hudson.model.AllView></views>' \
    '    <tabBar class="hudson.views.DefaultViewsTabBar"/>' \
    '  </folderViews>' \
    '  <healthMetrics/>' \
    '  <icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>' \
    '</com.cloudbees.hudson.plugins.folder.Folder>' > "$config"
  if curl --fail --silent "${JENKINS_URL%/}/job/${encoded_name}/api/json" >/dev/null 2>&1; then
    jenkins_post "job/${encoded_name}/config.xml" application/xml "$config"
  else
    jenkins_post "createItem?name=${encoded_name}" application/xml "$config"
  fi
  rm -f "$config"
}

create_child_folder() {
  local parent_path=$1
  local name=$2
  local encoded_name=${name// /%20}
  local config
  local item_status
  config=$(mktemp)
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder">' \
    '  <actions/>' \
    "  <description>Managed Jenkins folder: $name</description>" \
    '  <properties/>' \
    '  <folderViews class="com.cloudbees.hudson.plugins.folder.views.DefaultFolderViewHolder">' \
    '    <views><hudson.model.AllView><owner class="com.cloudbees.hudson.plugins.folder.Folder" reference="../../../.."/><name>All</name><filterExecutors>false</filterExecutors><filterQueue>false</filterQueue><properties class="hudson.model.View$PropertyList"/></hudson.model.AllView></views>' \
    '    <tabBar class="hudson.views.DefaultViewsTabBar"/>' \
    '  </folderViews><healthMetrics/><icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>' \
    '</com.cloudbees.hudson.plugins.folder.Folder>' > "$config"
  item_status=$(curl --silent --output /dev/null --write-out '%{http_code}' "${JENKINS_URL%/}/${parent_path}/job/${encoded_name}/api/json")
  if [[ "$item_status" != "404" ]]; then
    jenkins_post "${parent_path}/job/${encoded_name}/config.xml" application/xml "$config"
  else
    jenkins_post "${parent_path}/createItem?name=${encoded_name}" application/xml "$config"
  fi
  rm -f "$config"
}

create_pipeline() {
  local folder=$1
  local job=$2
  local script_file=$3
  local folder_encoded=${folder// /%20}
  local job_encoded=${job// /%20}
  local config
  config=$(mktemp)
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<flow-definition plugin="workflow-job">' '  <actions/>'
    printf '  <description>Managed by %s. Do not edit in the Jenkins UI.</description>\n' "$SCRIPT_DIR/setup.sh"
    printf '%s\n' '  <keepDependencies>false</keepDependencies>' '<properties>' '<jenkins.model.BuildDiscarderProperty><strategy class="hudson.tasks.LogRotator"><daysToKeep>30</daysToKeep><numToKeep>30</numToKeep><artifactDaysToKeep>-1</artifactDaysToKeep><artifactNumToKeep>-1</artifactNumToKeep></strategy></jenkins.model.BuildDiscarderProperty>'
    if [[ "$job" == "pr-checks" || "$job" == "deploy" ]]; then
      printf '%s\n' '<hudson.model.ParametersDefinitionProperty><parameterDefinitions>' \
        '<hudson.model.StringParameterDefinition><name>PR_NUMBER</name><description>GitHub pull request number</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
        '<hudson.model.StringParameterDefinition><name>HEAD_SHA</name><description>Exact PR head commit</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
        '<hudson.model.StringParameterDefinition><name>HEAD_REF</name><description>PR source branch</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
        '<hudson.model.StringParameterDefinition><name>BASE_REF</name><description>PR target branch</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>'
      if [[ "$job" == "deploy" ]]; then
        printf '%s\n' '<hudson.model.StringParameterDefinition><name>COMMENT_ID</name><description>GitHub deploy comment ID</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>'
      fi
      printf '%s\n' '</parameterDefinitions></hudson.model.ParametersDefinitionProperty>'
    fi
    printf '%s\n' '</properties>' '  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">' '    <script><![CDATA['
    sed 's/]]>/]]]]><![CDATA[>/g' "$script_file"
    printf '%s\n' ']]></script>' '    <sandbox>true</sandbox>' '  </definition>' '  <triggers/>' '  <disabled>false</disabled>' '</flow-definition>'
  } > "$config"
  if curl --fail --silent "${JENKINS_URL%/}/job/${folder_encoded}/job/${job_encoded}/api/json" >/dev/null 2>&1; then
    jenkins_post "job/${folder_encoded}/job/${job_encoded}/config.xml" application/xml "$config"
  else
    jenkins_post "job/${folder_encoded}/createItem?name=${job_encoded}" application/xml "$config"
  fi
  rm -f "$config"
}

create_pipeline_at() {
  local folder_path=$1
  local job=$2
  local script_file=$3
  local job_encoded=${job// /%20}
  local config
  config=$(mktemp)
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<flow-definition plugin="workflow-job">' '  <actions/>' \
      '  <description>Branch job template managed by jenkins/setup.sh.</description>' \
      '  <keepDependencies>false</keepDependencies>' '<properties>' \
      '<jenkins.model.BuildDiscarderProperty><strategy class="hudson.tasks.LogRotator"><daysToKeep>30</daysToKeep><numToKeep>30</numToKeep><artifactDaysToKeep>-1</artifactDaysToKeep><artifactNumToKeep>-1</artifactNumToKeep></strategy></jenkins.model.BuildDiscarderProperty>' \
      '<hudson.model.ParametersDefinitionProperty><parameterDefinitions>' \
      '<hudson.model.StringParameterDefinition><name>REPOSITORY</name><description>GitHub repository name</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
      '<hudson.model.StringParameterDefinition><name>PR_NUMBER</name><description>GitHub pull request number</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
      '<hudson.model.StringParameterDefinition><name>HEAD_SHA</name><description>Exact PR head commit</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
      '<hudson.model.StringParameterDefinition><name>HEAD_REF</name><description>PR source branch</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>' \
      '<hudson.model.StringParameterDefinition><name>BASE_REF</name><description>PR target branch</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>'
    if [[ "$folder_path" == */pull-request-deploy ]]; then
      printf '%s\n' '<hudson.model.StringParameterDefinition><name>COMMENT_ID</name><description>GitHub deploy comment ID</description><defaultValue></defaultValue><trim>false</trim></hudson.model.StringParameterDefinition>'
    fi
    printf '%s\n' '</parameterDefinitions></hudson.model.ParametersDefinitionProperty>' '</properties>' \
      '  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">' '    <script><![CDATA['
    sed 's/]]>/]]]]><![CDATA[>/g' "$script_file"
    printf '%s\n' ']]></script>' '    <sandbox>true</sandbox>' '  </definition>' '<triggers/>' '<disabled>false</disabled>' '</flow-definition>'
  } > "$config"
  if curl --fail --silent "${JENKINS_URL%/}/${folder_path}/job/${job_encoded}/api/json" >/dev/null 2>&1; then
    jenkins_post "${folder_path}/job/${job_encoded}/config.xml" application/xml "$config"
  else
    jenkins_post "${folder_path}/createItem?name=${job_encoded}" application/xml "$config"
  fi
  rm -f "$config"
}

mapfile -t REPOSITORIES < <(awk 'NF && $1 !~ /^#/ {print $1}' "$REPOSITORY_FILE" | sort -u)
if (( ${#REPOSITORIES[@]} == 0 )); then
  echo "No repositories found in $REPOSITORY_FILE" >&2
  exit 1
fi
repository_csv=$(IFS=,; echo "${REPOSITORIES[*]}")

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

render_pipeline "$SCRIPT_DIR/kubernetes-rbac.yaml" "$temporary_dir/kubernetes-rbac.yaml"
kubectl apply -f "$temporary_dir/kubernetes-rbac.yaml"

create_folder FLIPRLABS
for repository in "${REPOSITORIES[@]}"; do
  project_path="job/FLIPRLABS"
  create_child_folder "$project_path" "$repository"
  project_path="$project_path/job/$repository"
  create_child_folder "$project_path" pull-request-checker
  create_child_folder "$project_path" pull-request-deploy
  render_pipeline "$SCRIPT_DIR/pipelines/pr-checks.groovy" "$temporary_dir/pr-checks-$repository.groovy"
  render_pipeline "$SCRIPT_DIR/pipelines/deploy.groovy" "$temporary_dir/deploy-$repository.groovy"
  create_pipeline_at "$project_path/job/pull-request-checker" _template "$temporary_dir/pr-checks-$repository.groovy"
  create_pipeline_at "$project_path/job/pull-request-deploy" _template "$temporary_dir/deploy-$repository.groovy"
  echo "Configured FLIPRLABS/$repository/{pull-request-checker,pull-request-deploy}"
done

render_pipeline "$SCRIPT_DIR/pipelines/dispatcher.groovy" "$temporary_dir/dispatcher.groovy" '' "$repository_csv"
create_pipeline FLIPRLABS github-pr-dispatcher "$temporary_dir/dispatcher.groovy"

echo
echo "Configured ${#REPOSITORIES[@]} nested repository folders and FLIPRLABS/github-pr-dispatcher."
echo "Create Jenkins secret-text credential 'fliprlab-github-token', then run the dispatcher once."
