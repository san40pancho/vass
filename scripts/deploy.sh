#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploys one environment stage (qua | prd) to a SINGLE SAP Cloud Integration
# tenant, using per-environment packages and artifact suffixes.
#
#   usage: scripts/deploy.sh qua
#
# Required env vars (GitHub Actions secrets):
#   CPI_TOKEN_URL  CPI_CLIENT_ID  CPI_CLIENT_SECRET  CPI_API_URL
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:?usage: deploy.sh <qua|prd>}"
: "${CPI_TOKEN_URL:?missing}" "${CPI_CLIENT_ID:?missing}" "${CPI_CLIENT_SECRET:?missing}" "${CPI_API_URL:?missing}"

# --- config ----------------------------------------------------------------
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
ARTIFACT_NAME="${BASE_ID}${IFLOW_SUFFIX}"
PARAMS_FILE="config/${ENV_NAME}.params"
API="${CPI_API_URL%/}"

# --- helper: call the API, keep body + status, show body on error -----------
RESP_BODY=""
req() {  # req METHOD URL [json-file] -> echoes http status
  local method="$1" url="$2" data="${3:-}" out code
  out="$(mktemp)"
  if [[ -n "$data" ]]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${AUTH[@]}" \
             -H "Content-Type: application/json" --data-binary @"$data" "$url")
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${AUTH[@]}" \
             -H "Content-Length: 0" "$url")
  fi
  RESP_BODY="$(head -c 2000 "$out")"; rm -f "$out"
  echo "$code"
}
fail() { echo "::error::$1"; [[ -n "$RESP_BODY" ]] && echo "    tenant said: $RESP_BODY"; exit 1; }

# --- 1. package the exploded project ---------------------------------------
[[ -d "$SOURCE_DIR" ]] || { echo "::error::Source folder '$SOURCE_DIR' not found"; exit 1; }
[[ -f "$SOURCE_DIR/META-INF/MANIFEST.MF" ]] \
  || { echo "::error::'$SOURCE_DIR' has no META-INF/MANIFEST.MF"; exit 1; }

WORK="$(mktemp -d)"
cp -r "$SOURCE_DIR/." "$WORK/"

# The bundle metadata still carries the DEV artifact's identity. CPI rejects an
# upload whose manifest identity contradicts the requested Id, so rewrite it.
MF="$WORK/META-INF/MANIFEST.MF"
sed -i -E "s/^(Bundle-SymbolicName: *)[^;[:space:]]+/\1${ARTIFACT_ID}/" "$MF"
sed -i -E "s/^(Bundle-Name: *).*/\1${ARTIFACT_NAME}/" "$MF"
echo "==> Manifest identity:"
grep -E '^(Bundle-SymbolicName|Bundle-Name):' "$MF" | sed 's/^/    /'

FILE="$WORK.zip"
( cd "$WORK" && zip -qr "$FILE" . )
echo "==> Packaged $SOURCE_DIR ($(du -h "$FILE" | cut -f1))"
echo "==> [$ENV_NAME] Target: $ARTIFACT_ID in package $TARGET_PACKAGE"

# --- 2. OAuth token ---------------------------------------------------------
TOKEN_URL="$CPI_TOKEN_URL"
[[ "$TOKEN_URL" == *"/oauth/token"* ]] || TOKEN_URL="${TOKEN_URL%/}/oauth/token"
TOKEN=$(curl -sS -f -X POST "$TOKEN_URL" -u "${CPI_CLIENT_ID}:${CPI_CLIENT_SECRET}" \
          -d 'grant_type=client_credentials' | jq -r '.access_token')
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "::error::Could not obtain OAuth token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/json")

# --- 3. preflight: credential aliases --------------------------------------
if [[ -n "$REQUIRED_ALIASES" ]]; then
  IFS=',' read -ra ALIASES <<< "$REQUIRED_ALIASES"
  for RAW in "${ALIASES[@]}"; do
    ALIAS="$(echo "$RAW" | xargs)"; [[ -n "$ALIAS" ]] || continue
    FOUND=0
    for ENTITY in UserCredentials OAuth2ClientCredentials; do
      [[ "$(req GET "$API/${ENTITY}('${ALIAS}')")" == "200" ]] && { FOUND=1; break; }
    done
    [[ "$FOUND" == "1" ]] && echo "    preflight: alias '$ALIAS' exists ✓" \
      || fail "Credential alias '$ALIAS' not found in tenant security material"
  done
fi

# --- 4. ensure package exists ----------------------------------------------
CODE=$(req GET "$API/IntegrationPackages('${TARGET_PACKAGE}')")
if [[ "$CODE" == "404" ]]; then
  echo "==> Creating package $TARGET_PACKAGE"
  BODY="$(mktemp)"
  jq -n --arg id "$TARGET_PACKAGE" --arg name "$TARGET_PACKAGE_NAME" \
     '{Id:$id, Name:$name, ShortText:("Pipeline-managed: " + $name)}' > "$BODY"
  CODE=$(req POST "$API/IntegrationPackages" "$BODY")
  [[ "$CODE" =~ ^2 ]] || fail "Could not create package (HTTP $CODE)"
elif [[ "$CODE" != "200" ]]; then
  fail "Unexpected HTTP $CODE checking package $TARGET_PACKAGE"
fi

# --- 5. upsert design-time artifact ----------------------------------------
CONTENT_B64=$(base64 -w0 "$FILE")
BODY="$(mktemp)"
CODE=$(req GET "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')")
if [[ "$CODE" == "200" ]]; then
  echo "==> Updating existing artifact $ARTIFACT_ID"
  jq -n --arg name "$ARTIFACT_NAME" --arg content "$CONTENT_B64" \
     '{Name:$name, ArtifactContent:$content}' > "$BODY"
  CODE=$(req PUT "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')" "$BODY")
  [[ "$CODE" =~ ^2 ]] || fail "Update failed (HTTP $CODE)"
elif [[ "$CODE" == "404" ]]; then
  echo "==> Creating artifact $ARTIFACT_ID in $TARGET_PACKAGE"
  jq -n --arg id "$ARTIFACT_ID" --arg name "$ARTIFACT_NAME" --arg pkg "$TARGET_PACKAGE" \
        --arg content "$CONTENT_B64" \
     '{Id:$id, Name:$name, PackageId:$pkg, ArtifactContent:$content}' > "$BODY"
  CODE=$(req POST "$API/IntegrationDesigntimeArtifacts" "$BODY")
  [[ "$CODE" =~ ^2 ]] || fail "Create failed (HTTP $CODE)"
else
  fail "Unexpected HTTP $CODE checking artifact $ARTIFACT_ID"
fi
rm -f "$BODY"

# --- 6. apply externalized parameters ---------------------------------------
if [[ -f "$PARAMS_FILE" ]]; then
  echo "==> Applying externalized parameters from $PARAMS_FILE"
  while IFS='=' read -r KEY VALUE; do
    [[ -z "${KEY// }" || "$KEY" =~ ^[[:space:]]*# ]] && continue
    KEY="$(echo "$KEY" | xargs)"; VALUE="$(echo "$VALUE" | xargs)"
    PBODY="$(mktemp)"
    jq -n --arg v "$VALUE" '{ParameterValue:$v, DataType:"xsd:string"}' > "$PBODY"
    CODE=$(req PUT "$API/IntegrationDesigntimeArtifacts(Id='${ARTIFACT_ID}',Version='active')/\$links/Configurations('${KEY}')" "$PBODY")
    rm -f "$PBODY"
    [[ "$CODE" =~ ^2 ]] && echo "    $KEY = $VALUE ✓" \
      || fail "Could not set parameter '$KEY' (HTTP $CODE) — is it externalized in the iFlow?"
  done < "$PARAMS_FILE"
fi

# --- 7. deploy and wait ------------------------------------------------------
echo "==> Deploying $ARTIFACT_ID"
CODE=$(req POST "$API/DeployIntegrationDesigntimeArtifact?Id='${ARTIFACT_ID}'&Version='active'")
[[ "$CODE" =~ ^2 ]] || fail "Deploy call failed (HTTP $CODE)"

echo "==> Waiting for runtime status STARTED"
STATUS=""
for i in $(seq 1 24); do
  sleep 10
  STATUS=$(curl -sS "${AUTH[@]}" "$API/IntegrationRuntimeArtifacts('${ARTIFACT_ID}')" \
             | jq -r '.d.Status // empty' || true)
  echo "    attempt $i/24 → ${STATUS:-<not visible yet>}"
  case "$STATUS" in
    STARTED)
      echo "==> ✅ [$ENV_NAME] $ARTIFACT_ID deployed and STARTED"; exit 0 ;;
    ERROR)
      echo "::error::Deployment ended in ERROR — details:"
      curl -sS "${AUTH[@]}" "$API/IntegrationRuntimeArtifacts('${ARTIFACT_ID}')/ErrorInformation/\$value" || true
      exit 1 ;;
  esac
done
echo "::error::Timed out waiting for runtime status (last: ${STATUS:-unknown})"
exit 1
