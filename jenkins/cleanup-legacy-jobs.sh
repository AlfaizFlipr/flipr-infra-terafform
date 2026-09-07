#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${JENKINS_URL:=http://127.0.0.1:18080}"

mapfile -t repositories < <(
  awk 'NF && $1 !~ /^#/ {print $1}' "$SCRIPT_DIR/repositories.txt"
  printf '%s\n' amazon-inbound cred impact
)

cookie_jar=$(mktemp)
trap 'rm -f "$cookie_jar"' EXIT
crumb=$(curl --fail --silent --show-error -c "$cookie_jar" \
  "${JENKINS_URL%/}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")

for repository in "${repositories[@]}"; do
  encoded=${repository// /%20}
  item_url="${JENKINS_URL%/}/job/${encoded}"
  if curl --fail --silent "$item_url/api/json" >/dev/null 2>&1; then
    # Only remove a legacy folder when it contains pr-checks or deploy.
    if curl --silent "$item_url/api/json" | grep -Eq '"name"[[:space:]]*:[[:space:]]*"(pr-checks|deploy)"'; then
      curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" "$item_url/doDelete"
      echo "Removed legacy Jenkins folder: $repository"
    fi
  fi
done
