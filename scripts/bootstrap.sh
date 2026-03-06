#!/usr/bin/env bash
# =============================================================================
# Bootstrap — Create OBS + KMS with local state (bootstrap/ project)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/../bootstrap"
INFRA_DIR="${SCRIPT_DIR}/../infra"
APPS_DIR="${SCRIPT_DIR}/../apps"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[bootstrap]${NC} $*"; }
err() { echo -e "${RED}[bootstrap]${NC} $*" >&2; }

for var in TF_VAR_otc_access_key TF_VAR_otc_secret_key TF_VAR_otc_domain_name; do
  if [[ -z "${!var:-}" ]]; then
    err "Missing: $var"
    exit 1
  fi
done

command -v tofu >/dev/null || { err "tofu not found"; exit 1; }

cd "$BOOTSTRAP_DIR"

log "Creating OBS bucket + KMS key..."
tofu init -input=false
tofu apply -auto-approve -input=false

log "Updating backend config..."
tofu output -raw backend_config > "${INFRA_DIR}/backend.tf"
tofu output -raw apps_backend_config > "${APPS_DIR}/backend.tf"

BUCKET=$(tofu output -raw bucket_name)
KMS_ID=$(tofu output -raw kms_key_id)

echo ""
log "Bootstrap complete:"
log "   OBS Bucket: ${BUCKET}"
log "   KMS Key:    ${KMS_ID}"
log "   Infra Backend: ${INFRA_DIR}/backend.tf (updated)"
log "   Apps Backend: ${APPS_DIR}/backend.tf (updated)"
echo ""
log "Next: cd infra && tofu init && tofu apply"
