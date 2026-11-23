#!/usr/bin/env bash
# =============================================================================
# Bootstrap — Create OBS + KMS with local state (bootstrap/ project)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/../bootstrap"
INFRA_DIR="${SCRIPT_DIR}/../infra"
WORKLOADS_DIR="${SCRIPT_DIR}/../workloads"

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
command -v jq >/dev/null || { err "jq not found"; exit 1; }

cd "$BOOTSTRAP_DIR"

log "Creating OBS bucket + KMS key..."
tofu init -input=false
tofu apply -auto-approve -input=false

log "Updating backend config..."
tofu output -raw backend_config > "${INFRA_DIR}/backend.tf"
tofu output -raw workloads_backend_config > "${WORKLOADS_DIR}/backend.tf"

# Per-environment state keys: <env>/<stack>/terraform.tfstate
mkdir -p "${INFRA_DIR}/envs" "${WORKLOADS_DIR}/envs"
for env in dev prod; do
  tofu output -json backend_tfvars | jq -j --arg env "$env" '.[$env].infra' > "${INFRA_DIR}/envs/${env}.backend.tfvars"
  tofu output -json backend_tfvars | jq -j --arg env "$env" '.[$env].workloads' > "${WORKLOADS_DIR}/envs/${env}.backend.tfvars"
done

BUCKET=$(tofu output -raw bucket_name)
KMS_ID=$(tofu output -raw kms_key_id)

echo ""
log "Bootstrap complete:"
log "   OBS Bucket: ${BUCKET}"
log "   KMS Key:    ${KMS_ID}"
log "   Infra Backend: ${INFRA_DIR}/backend.tf (updated)"
log "   Workloads Backend: ${WORKLOADS_DIR}/backend.tf (updated)"
log "   State keys: <dev|prod>/<infra|workloads>/terraform.tfstate (envs/*.backend.tfvars)"
echo ""
log "Next: cd infra && tofu init -backend-config=envs/dev.backend.tfvars && tofu apply -var-file=envs/dev.tfvars"
