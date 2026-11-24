#!/usr/bin/env bash
# Initialize the selected stack and verify its state key using local backend metadata.
set -euo pipefail
case "${1:-}" in infra|workloads) stack=$1 ;; *) echo "Usage: TF_VAR_environment=<dev|prod> bash scripts/init-stack.sh <infra|workloads>" >&2; exit 2 ;; esac
case "${TF_VAR_environment:-}" in dev|prod) ;; *) echo "Set TF_VAR_environment to dev or prod." >&2; exit 2 ;; esac
cd "$(dirname "$0")/../$stack"
tofu init -reconfigure -input=false
meta="${TF_DATA_DIR:-.terraform}/terraform.tfstate"
key="$TF_VAR_environment/$stack/terraform.tfstate"
if ! jq -e --arg key "$key" '.backend.type == "s3" and .backend.config.key == $key' "$meta" >/dev/null; then
  echo "Expected S3 backend with state key $key; refusing to continue." >&2
  exit 1
fi
echo "Initialized $key. OBS does not lock the state; do not overlap local and CI writes."
