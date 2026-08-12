#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploys one environment stage (dev | qua | prd) to a SINGLE SAP Cloud
# Integration tenant, using per-environment packages and artifact suffixes.
#
#   usage: scripts/deploy.sh dev
#
# What it does, in order:
#   1. sanity checks   — config parses, artifact zip is a valid iFlow bundle
#   2. OAuth token     — client-credentials flow against the tenant
#   3. alias preflight — verifies required credential aliases exist in the
#                        tenant's security material (fail fast, not at runtime)
#   4. package         — creates the target package if it doesn't exist yet
#   5. upsert artifact — uploads src/<IFLOW_ID>.zip as <IFLOW_ID><SUFFIX>
#   6. configure       — fills the externalized parameters ("the blanks")
#                        with the values from config/<env>.params
#   7. deploy + poll   — deploys and waits until runtime status is STARTED
#
# Required env vars (GitHub Actions secrets):
#   CPI_TOKEN_URL  CPI_CLIENT_ID  CPI_CLIENT_SECRET  CPI_API_URL
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:?usage: deploy.sh <dev|qua|prd>}"
: "${CPI_TOKEN_URL:?missing}" "${CPI_CLIENT_ID:?missing}" "${CPI_CLIENT_SECRET:?missing}" "${CPI_API_URL:?missing}"

# --- 1. Load config + sanity checks ----------------------------------------
for f in "config/base.env" "config/${ENV_NAME}.env"; do
  [[ -f "$f" ]] || { echo "::error::Missing config file $f"; exit 1; }
  # shellcheck disable=SC1090
  source "$f"
done
: "${SOURCE_DIR:?not set in base.env}" "${BASE_ID:?not set in base.env}" "${IFLOW_NAME:?not set in base.env}"
: "${IFLOW_SUFFIX:?not set in ${ENV_NAME}.env}" "${TARGET_PACKAGE:?not set in ${ENV_NAME}.env}"
TARGET_PACKAGE_NAME="${TARGET_PACKAGE_NAME:-$TARGET_PACKAGE}"
REQUIRED_ALIASES="${REQUIRED_ALIASES:-}"

ARTIFACT_ID="${BASE_ID}${IFLOW_SUFFIX}"
ARTIFACT_NAME="${IFLOW_NAME} (${ENV_NAME^^})"
PARAMS_FILE="config/${ENV_NAME}.params"
API="${CPI_API_URL%/}"

# CPI's Git Push stores the iFlow as an exploded project folder; the OData API
# expects a zip whose ROOT contains META-INF/ — so repackage it here.
[[ -d "$SOURCE_DIR" ]] || { echo "::error::Source folder '$SOURCE_DIR' not found in repo"; exit 1; }
[[ -f "$SOURCE_DIR/META-INF/MANIFEST.MF" ]] \
  || { echo "::error::'$SOURCE_DIR' is not an iFlow project (no META-INF/MANIFEST.MF)"; exit 1; }

FILE="$(mktemp -d)/${BASE_ID}.zip"
( cd "$SOURCE_DIR" && zip -qr "$FILE" . -x '.git/*' )
echo "==> Packaged $SOURCE_DIR → $(basename "$FILE") ($(du -h "$FILE" | cut -f1))"
echo "==> [$ENV_NAME] Deploying $ARTIFACT_ID into package $TARGET_PACKAGE"

# --- 2. OAuth token ---------------------------------------------------------
TOKEN_URL="$CPI_TOKEN_URL"
[[ "$TOKEN_URL" == *"/oauth/token"* ]] || TOKEN_URL="${TOKEN_URL%/}/oauth/token"
TOKEN=$(curl -sS -f -X POST "$TOKEN_URL" \
          -u "${CPI_CLIENT_ID}:${CPI_CLIENT_SECRET}" \
          -d 'grant_type=client_credentials' | jq -r '.access_token')
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "::error::Could not obtain OAuth token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/json")

# --- 3. Preflight: required credential aliases exist ------------------------
if [[ -n "$REQUIRED_ALIASES" ]]; then
  IFS=',' read -ra ALIASES <<< "$REQUIRED_ALIASES"
  for RAW in "${ALIASES[@]}"; do
    ALIAS="$(echo "$RAW" | xargs)"   # trim whitespace
    [[ -n "$ALIAS" ]] || continue
    FOUND=0
    for ENTITY in UserCredentials OAuth2ClientCredentials; do
      HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" \
              "$API/${ENTITY}('${ALIAS}')") || HTTP=000
      [[ "$HTTP" == "200" ]] && { FOUND=1; break; }
    done
    if [[ "$FOUND" == "1" ]]; then
      echo "    preflight: alias '$ALIAS' exists ✓"
    else
      echo "::error::Credential alias '$ALIAS' not found in tenant security material — create it before deploying $ENV_NAME"
      exit 1
    fi
  done
fi

# --- 4. Ensure target package exists ----------------------------------------
HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" \
        "$API/IntegrationPackages('${TARGET_PACKAGE}')")
if [[ "$HTTP" == "404" ]]; then
  echo "==> Package $TARGET_PACKAGE not found — creating it"
  jq -n --arg id "$TARGET_PACKAGE" --arg name "$TARGET_PACKAGE_NAME" \
     '{Id:$id, Name:$name, ShortText:("Pipeline-managed package for " + $name)}' \
  | curl -sS -f -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
      "$API/IntegrationPackages" -d @- > /dev/null
elif [[ "$HTTP" != "200" ]]; then
  echo "::error::Unexpected HTTP $HTTP checking package (check CPI_API_URL / roles)"
  exit 1
fi

# --- 5. Upsert design-time artifact ------------------------------------------
CONTENT_B64=$(base64 -w0 "$FILE")
HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" \
        "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')")
if [[ "$HTTP" == "200" ]]; then
  echo "==> Updating existing artifact $ARTIFACT_ID"
  jq -n --arg name "$ARTIFACT_NAME" --arg content "$CONTENT_B64" \
     '{Name:$name, ArtifactContent:$content}' \
  | curl -sS -f -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
      "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')" \
      -d @- > /dev/null
elif [[ "$HTTP" == "404" ]]; then
  echo "==> Creating artifact $ARTIFACT_ID in $TARGET_PACKAGE"
  jq -n --arg id "$ARTIFACT_ID" --arg name "$ARTIFACT_NAME" --arg pkg "$TARGET_PACKAGE" --arg content "$CONTENT_B64" \
     '{Id:$id, Name:$name, PackageId:$pkg, ArtifactContent:$content}' \
  | curl -sS -f -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
      "$API/IntegrationDesigntimeArtifacts" -d @- > /dev/null
else
  echo "::error::Unexpected HTTP $HTTP checking artifact"
  exit 1
fi

# --- 6. Fill the blanks: apply externalized parameters ------------------------
if [[ -f "$PARAMS_FILE" ]]; then
  echo "==> Applying externalized parameters from $PARAMS_FILE"
  while IFS='=' read -r KEY VALUE; do
    # skip comments and blank lines
    [[ -z "$KEY" || "$KEY" =~ ^[[:space:]]*# ]] && continue
    KEY="$(echo "$KEY" | xargs)"; VALUE="$(echo "$VALUE" | xargs)"
    jq -n --arg v "$VALUE" '{ParameterValue:$v, DataType:"xsd:string"}' \
    | curl -sS -f -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
        "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')/\$links/Configurations('${KEY}')" \
        -d @- > /dev/null \
      && echo "    $KEY = $VALUE ✓" \
      || { echo "::error::Failed to set parameter '$KEY' (does it exist / is it externalized in the iFlow?)"; exit 1; }
  done < "$PARAMS_FILE"
else
  echo "==> No $PARAMS_FILE — skipping parameter configuration"
fi

# --- 7. Deploy and wait for STARTED -------------------------------------------
echo "==> Triggering deployment of $ARTIFACT_ID"
curl -sS -f -X POST "${AUTH[@]}" -H "Content-Length: 0" \
  "$API/DeployIntegrationDesigntimeArtifact?Id='${ARTIFACT_ID}'&Version='active'" > /dev/null

echo "==> Waiting for runtime to report STARTED"
STATUS=""
for i in $(seq 1 24); do
  sleep 10
  STATUS=$(curl -sS "${AUTH[@]}" "$API/IntegrationRuntimeArtifacts('${ARTIFACT_ID}')" \
             | jq -r '.d.Status // empty' || true)
  echo "    attempt $i/24 → ${STATUS:-<not yet visible>}"
  case "$STATUS" in
    STARTED)
      echo "==> ✅ [$ENV_NAME] $ARTIFACT_ID deployed and STARTED"
      exit 0 ;;
    ERROR)
      echo "::error::Deployment ended in ERROR — details:"
      curl -sS "${AUTH[@]}" \
        "$API/IntegrationRuntimeArtifacts('${ARTIFACT_ID}')/ErrorInformation/\$value" || true
      exit 1 ;;
  esac
done
echo "::error::Timed out waiting for runtime status (still '${STATUS:-unknown}')"
exit 1
