#!/usr/bin/env bash
set -euo pipefail

# Detect environment
if [[ "$GITHUB_REF" == "refs/heads/accept" ]]; then
  TARGET_ENV="ACCEPT"
  CLIENT_ID="$DEVPORTAL_CLIENT_ID_ACCEPT"
  CLIENT_SECRET="$DEVPORTAL_CLIENT_SECRET_ACCEPT"
  API_BASE="https://ansys-a.devportal.io"
elif [[ "$GITHUB_REF" == "refs/heads/main" ]]; then
  TARGET_ENV="PROD"
  CLIENT_ID="$DEVPORTAL_CLIENT_ID_PROD"
  CLIENT_SECRET="$DEVPORTAL_CLIENT_SECRET_PROD"
  API_BASE="https://developer.ansys.com"
else
  echo "Unsupported branch"
  exit 1
fi

# Mask secrets
echo "::add-mask::$CLIENT_SECRET"

# Version detection
VERSION_ROOT="product/versions"

if [[ ! -d "$VERSION_ROOT" ]]; then
  echo "❌ Version root not found: $VERSION_ROOT"
  exit 1
fi

VERSION_FOLDERS=$(ls -d "$VERSION_ROOT"/*/ \
  | sed "s|$VERSION_ROOT/||;s|/||")

LATEST_VERSION=$(
  printf "%s\n" $VERSION_FOLDERS \
  | awk -F'[R.]' '
    {
      year=$1
      release=$2
      sp=0
      if ($3 ~ /^SP/) {
        sub("SP","",$3)
        sp=$3
      }
      printf "%04d %02d %02d %s\n", year, release, sp, $0
    }
  ' \
  | sort -n \
  | tail -1 \
  | awk '{print $4}'
)

# OAuth token
TOKEN=$(curl -s -X POST "$API_BASE/oauth/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" | jq -r '.access_token')

echo "::add-mask::$TOKEN"

# Payload
PAYLOAD=$(jq -n \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg sha "$GITHUB_SHA" \
  --arg branch "${GITHUB_REF##*/}" \
  --arg env "$TARGET_ENV" \
  --arg latest "$LATEST_VERSION" \
  --argjson folders "$(printf '%s\n' $VERSION_FOLDERS | jq -R . | jq -s .)" \
  '{
    repository: $repo,
    commitSha: $sha,
    sourceBranch: $branch,
    targetEnvironment: $env,
    versions: {
      latest: $latest,
      stable: $latest
    },
    versionFolders: $folders
  }')

# Migration request
STATUS=$(curl -s -w "%{http_code}" -o response.json \
  -X POST "$API_BASE/api/migrations" \
  -H "Authorization: Bearer '"$TOKEN"'" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if [[ "$STATUS" =~ ^2 ]]; then
  echo "✅ Success – Queued"
  echo "🔗 $API_BASE/api/migrations"
else
  echo "❌ Migration failed ($STATUS)"
  cat response.json
  exit 1
fi
