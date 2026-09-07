#!/usr/bin/env bash
# Create/update the two GitHub Organization Folders used by this repository.
#
# Required environment variables:
#   JENKINS_USER              Jenkins administrator user name
#   JENKINS_API_TOKEN         API token created in that user's Jenkins profile
#   GITHUB_CREDENTIAL_ID      Existing Jenkins GitHub App/token credential ID
# Optional:
#   JENKINS_URL               Defaults to http://127.0.0.1:18080
#   GITHUB_ORGANIZATION       Defaults to flipr-Infra-test
#   GITHUB_API_URL            Defaults to https://api.github.com
#
# Example:
# export JENKINS_USER=admin
# export JENKINS_API_TOKEN='paste-an-api-token-here'
# export GITHUB_CREDENTIAL_ID=github-flipr-infra-test
# ./Jenkins/setup-org-folders.sh

set -Eeuo pipefail

: "${JENKINS_USER:?Set JENKINS_USER to a Jenkins administrator user.}"
: "${JENKINS_API_TOKEN:?Set JENKINS_API_TOKEN to a Jenkins API token.}"
: "${GITHUB_CREDENTIAL_ID:?Set GITHUB_CREDENTIAL_ID to the existing Jenkins GitHub credential ID.}"

JENKINS_URL=${JENKINS_URL:-http://127.0.0.1:18080}
GITHUB_ORGANIZATION=${GITHUB_ORGANIZATION:-flipr-Infra-test}
GITHUB_API_URL=${GITHUB_API_URL:-https://api.github.com}
readonly JENKINS_URL GITHUB_ORGANIZATION GITHUB_API_URL

for command in curl jq mktemp; do
  command -v "$command" >/dev/null || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

api() {
  curl --fail --silent --show-error \
    --user "${JENKINS_USER}:${JENKINS_API_TOKEN}" \
    "$@"
}

crumb_json=$(api "${JENKINS_URL}/crumbIssuer/api/json")
crumb_field=$(jq -r '.crumbRequestField' <<<"$crumb_json")
crumb_value=$(jq -r '.crumb' <<<"$crumb_json")
test "$crumb_field" != null
test "$crumb_value" != null

api_post() {
  api -X POST -H "${crumb_field}: ${crumb_value}" "$@"
}

require_plugin() {
  local plugin=$1
  if ! api "${JENKINS_URL}/pluginManager/api/json?depth=1" \
      | jq -e --arg plugin "$plugin" '.plugins[] | select(.shortName == $plugin and .active == true)' >/dev/null; then
    echo "Required active Jenkins plugin is missing: ${plugin}" >&2
    exit 1
  fi
}

require_plugin github-branch-source
require_plugin workflow-multibranch
require_plugin pipeline-model-definition
require_plugin credentials-binding
require_plugin ansicolor
require_plugin junit

folder_config() {
  local script_path=$1
  cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<jenkins.branch.OrganizationFolder>
  <actions/>
  <description>Managed by Jenkins/setup-org-folders.sh. GitHub organization: ${GITHUB_ORGANIZATION}</description>
  <properties/>
  <folderViews class="com.cloudbees.hudson.plugins.folder.views.DefaultFolderViewHolder">
    <views>
      <hudson.model.AllView><owner class="jenkins.branch.OrganizationFolder" reference="../../../.."/><name>all</name><filterExecutors>false</filterExecutors><filterQueue>false</filterQueue><properties class="java.util.concurrent.CopyOnWriteArrayList"/></hudson.model.AllView>
    </views>
    <tabBar class="hudson.views.DefaultViewsTabBar"/>
  </folderViews>
  <healthMetrics>
    <com.cloudbees.hudson.plugins.folder.health.WorstChildHealthMetric><nonRecursive>false</nonRecursive></com.cloudbees.hudson.plugins.folder.health.WorstChildHealthMetric>
  </healthMetrics>
  <icon class="jenkins.branch.MetadataActionFolderIcon"><owner class="jenkins.branch.OrganizationFolder" reference="../.."/></icon>
  <navigators>
    <org.jenkinsci.plugins.github__branch__source.GitHubSCMNavigator>
      <apiUri>${GITHUB_API_URL}</apiUri>
      <credentialsId>${GITHUB_CREDENTIAL_ID}</credentialsId>
      <traits>
        <org.jenkinsci.plugins.github__branch__source.OriginPullRequestDiscoveryTrait>
          <strategyId>1</strategyId>
        </org.jenkinsci.plugins.github__branch__source.OriginPullRequestDiscoveryTrait>
      </traits>
      <repoOwner>${GITHUB_ORGANIZATION}</repoOwner>
    </org.jenkinsci.plugins.github__branch__source.GitHubSCMNavigator>
  </navigators>
  <projectFactories>
    <org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProjectFactory>
      <scriptPath>${script_path}</scriptPath>
    </org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProjectFactory>
  </projectFactories>
  <orphanedItemStrategy class="com.cloudbees.hudson.plugins.folder.computed.DefaultOrphanedItemStrategy">
    <pruneDeadBranches>true</pruneDeadBranches><daysToKeep>14</daysToKeep><numToKeep>20</numToKeep>
  </orphanedItemStrategy>
  <triggers>
    <com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger><spec>H H * * *</spec><interval>86400000</interval></com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger>
  </triggers>
  <disabled>false</disabled>
</jenkins.branch.OrganizationFolder>
EOF
}

upsert_folder() {
  local folder_name=$1 script_path=$2 encoded_name config_file
  encoded_name=${folder_name// /%20}
  config_file=$(mktemp)
  trap 'rm -f "$config_file"' RETURN
  folder_config "$script_path" >"$config_file"

  if api "${JENKINS_URL}/job/${encoded_name}/api/json" >/dev/null 2>&1; then
    echo "Updating Organization Folder: ${folder_name}"
    api_post --data-binary @"$config_file" "${JENKINS_URL}/job/${encoded_name}/config.xml" >/dev/null
  else
    echo "Creating Organization Folder: ${folder_name}"
    api_post --data-binary @"$config_file" \
      "${JENKINS_URL}/createItem?name=${encoded_name}&mode=jenkins.branch.OrganizationFolder&from=" >/dev/null
  fi

  echo "Starting organization scan: ${folder_name}"
  api_post "${JENKINS_URL}/job/${encoded_name}/build?delay=0sec" >/dev/null
}

upsert_folder 'PR Validation' 'Jenkins/pr-validation/Jenkinsfile'
upsert_folder 'Test Deploy' 'Jenkins/deploy-test/Jenkinsfile'

echo
echo 'Done. Open Jenkins → PR Validation and Test Deploy to monitor the scans.'
echo 'Configure GitHub App webhooks with an externally reachable HTTPS Jenkins URL; GitHub cannot reach 127.0.0.1.'
