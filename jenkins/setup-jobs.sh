#!/usr/bin/env bash
set -Eeuo pipefail

JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:18080}"
JENKINS_USER="${JENKINS_USER:-admin}"
GITHUB_CREDENTIAL_ID="${GITHUB_CREDENTIAL_ID:-}"
CI_JOB_NAME="${CI_JOB_NAME:-infra-pr-validation}"
DEPLOY_JOB_NAME="${DEPLOY_JOB_NAME:-infra-deploy}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_command curl
require_command git
require_command kubectl

remote_url="${GITHUB_REPOSITORY_URL:-$(git remote get-url origin)}"
remote_path="${remote_url#*github.com[:/]}"
remote_path="${remote_path%.git}"
GITHUB_OWNER="${GITHUB_OWNER:-${remote_path%%/*}}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-${remote_path#*/}}"

for value in "$GITHUB_OWNER" "$GITHUB_REPOSITORY" "$CI_JOB_NAME" "$DEPLOY_JOB_NAME"; do
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsafe or invalid value: $value" >&2
    exit 1
  fi
done

if [[ -n "$GITHUB_CREDENTIAL_ID" && ! "$GITHUB_CREDENTIAL_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Unsafe GITHUB_CREDENTIAL_ID: $GITHUB_CREDENTIAL_ID" >&2
  exit 1
fi

if [[ -z "${JENKINS_PASSWORD:-}" ]]; then
  JENKINS_PASSWORD="$(
    kubectl get secret jenkins -n jenkins \
      -o jsonpath='{.data.jenkins-admin-password}' | base64 --decode
  )"
fi

if ! curl --silent --show-error --fail \
  --user "$JENKINS_USER:$JENKINS_PASSWORD" \
  "$JENKINS_URL/api/json" >/dev/null; then
  echo "Cannot authenticate to Jenkins at $JENKINS_URL." >&2
  echo "Start the port-forward first:" >&2
  echo "  kubectl -n jenkins port-forward --address 127.0.0.1 svc/jenkins 18080:8080" >&2
  exit 1
fi

crumb_json="$(
  curl --silent --show-error --fail \
    --user "$JENKINS_USER:$JENKINS_PASSWORD" \
    "$JENKINS_URL/crumbIssuer/api/json"
)"
crumb_field="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')"
crumb_value="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"

if [[ -z "$crumb_field" || -z "$crumb_value" ]]; then
  echo "Could not obtain a Jenkins CSRF crumb." >&2
  exit 1
fi
groovy_file="$(mktemp /tmp/jenkins-jobs.XXXXXX.groovy)"
trap 'rm -f "$groovy_file"' EXIT

sed \
  -e "s|@@OWNER@@|$GITHUB_OWNER|g" \
  -e "s|@@REPOSITORY@@|$GITHUB_REPOSITORY|g" \
  -e "s|@@CREDENTIAL_ID@@|$GITHUB_CREDENTIAL_ID|g" \
  -e "s|@@CI_JOB@@|$CI_JOB_NAME|g" \
  -e "s|@@DEPLOY_JOB@@|$DEPLOY_JOB_NAME|g" \
  "$(dirname "$0")/setup-jobs.groovy.tmpl" >"$groovy_file"

echo "Configuring Jenkins jobs for $GITHUB_OWNER/$GITHUB_REPOSITORY ..."
curl --silent --show-error --fail \
  --user "$JENKINS_USER:$JENKINS_PASSWORD" \
  --header "$crumb_field: $crumb_value" \
  --data-urlencode "script@$groovy_file" \
  "$JENKINS_URL/scriptText"

echo
echo "Created or updated:"
echo "  $JENKINS_URL/job/$CI_JOB_NAME/"
echo "  $JENKINS_URL/job/$DEPLOY_JOB_NAME/"
echo
echo "Jenkins is scanning the repository now."
