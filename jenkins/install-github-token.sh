#!/usr/bin/env bash
set -Eeuo pipefail

: "${JENKINS_URL:=http://127.0.0.1:18080}"
: "${GITHUB_ORG:=fliprlab}"

read -r -s -p "GitHub token: " GITHUB_TOKEN
printf '\n'
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Token cannot be empty." >&2
  exit 1
fi

temporary_dir=$(mktemp -d)
trap 'unset GITHUB_TOKEN; rm -rf "$temporary_dir"' EXIT

github_headers=(
  -H "Accept: application/vnd.github+json"
  -H "Authorization: Bearer $GITHUB_TOKEN"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

curl --fail --silent --show-error "${github_headers[@]}" https://api.github.com/user > "$temporary_dir/user.json"
login=$(sed -n 's/^[[:space:]]*"login": "\([^"]*\)",*$/\1/p' "$temporary_dir/user.json" | head -1)
echo "Authenticated to GitHub as: $login"

curl --fail --silent --show-error "${github_headers[@]}" \
  "https://api.github.com/orgs/${GITHUB_ORG}/repos?type=all&per_page=100" > "$temporary_dir/repos.json"

credential_url="${JENKINS_URL%/}/credentials/store/system/domain/_/credential/fliprlab-github-token"
if curl --fail --silent "$credential_url/api/json" >/dev/null 2>&1; then
  endpoint="credentials/store/system/domain/_/credential/fliprlab-github-token/config.xml"
else
  endpoint="credentials/store/system/domain/_/createCredentials"
fi

cat > "$temporary_dir/credential.xml" <<EOF
<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl plugin="plain-credentials">
  <scope>GLOBAL</scope>
  <id>fliprlab-github-token</id>
  <description>Read-only GitHub token for Flipr Labs test pipelines</description>
  <secret>${GITHUB_TOKEN}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
EOF

cookie_jar=$(mktemp)
crumb=$(curl --fail --silent --show-error -c "$cookie_jar" \
  "${JENKINS_URL%/}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
curl --fail --silent --show-error -b "$cookie_jar" -X POST -H "$crumb" \
  -H 'Content-Type: application/xml' --data-binary "@$temporary_dir/credential.xml" \
  "${JENKINS_URL%/}/$endpoint"

echo "Stored Jenkins credential: fliprlab-github-token"
echo "Accessible ${GITHUB_ORG} repositories:"
sed -n 's/^[[:space:]]*"name": "\([^"]*\)",*$/\1/p' "$temporary_dir/repos.json" | sort -u
