#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CURL_ARGS=(--silent --show-error --connect-timeout 5 --max-time 20)
for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 1; }
done

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'

# Read defaults from tfvars
TFVARS="$REPO_DIR/apps/terraform.tfvars"
DEFAULT_HOSTNAME=""
if [ -f "$TFVARS" ]; then
  BAO_HOST=$(grep 'openbao_hostname' "$TFVARS" 2>/dev/null | cut -d'"' -f2 || true)
fi

# Try to get zone from infra tfvars
INFRA_TFVARS="$REPO_DIR/infra/terraform.tfvars"
if [ -f "$INFRA_TFVARS" ]; then
  ZONE=$(grep 'dns_zone_name' "$INFRA_TFVARS" 2>/dev/null | cut -d'"' -f2 | sed 's/\.$//' || true)
fi

if [ -n "${BAO_HOST:-}" ] && [ -n "${ZONE:-}" ]; then
  DEFAULT_HOSTNAME="${BAO_HOST}.${ZONE}"
fi

echo -e "${Y}Demo App OpenBao Setup${N}"
echo ""

# OpenBao address
if [ -n "$DEFAULT_HOSTNAME" ]; then
  read -rp "OpenBao URL [https://${DEFAULT_HOSTNAME}]: " BAO_URL
  BAO_URL=${BAO_URL:-"https://${DEFAULT_HOSTNAME}"}
else
  read -rp "OpenBao URL: " BAO_URL
fi

if [ -z "$BAO_URL" ]; then
  echo -e "${R}OpenBao URL required${N}"
  exit 1
fi
BAO_URL=${BAO_URL%/}

if ! curl "${CURL_ARGS[@]}" --fail \
  "${BAO_URL}/v1/sys/health?standbyok=true&perfstandbyok=true" > /dev/null; then
  echo "OpenBao is not reachable or not ready. Run scripts/openbao-init.sh (initialize + unseal) first." >&2
  exit 1
fi

read -rp "Admin username [admin]: " BAO_USER
BAO_USER=${BAO_USER:-admin}
read -rsp "Admin password: " BAO_PASS
echo ""

# Login
echo -e "${Y}Logging in...${N}"
LOGIN_USER=$(printf '%s' "$BAO_USER" | jq -sRr @uri)
if ! TOKEN=$(printf '%s' "$BAO_PASS" | jq -sR '{password: .}' |
  curl "${CURL_ARGS[@]}" --fail -H 'Content-Type: application/json' \
    --data-binary @- "${BAO_URL}/v1/auth/userpass/login/${LOGIN_USER}" |
  jq -er '.auth.client_token | strings | select(length > 0)'); then
  echo -e "${R}OpenBao login failed. Check the userpass credentials.${N}" >&2
  exit 1
fi
unset BAO_PASS

bao_api() {
  curl "${CURL_ARGS[@]}" --header @<(printf 'Authorization: Bearer %s\n' "$TOKEN") \
    -H 'Content-Type: application/json' "$@"
}

echo -e "${G}Logged in${N}"

# Policy
echo -e "${Y}Creating policy...${N}"
bao_api --fail -X PUT "${BAO_URL}/v1/sys/policies/acl/demo-app" \
  -d '{"policy":"path \"kv/data/demo/*\" {\n  capabilities = [\"create\", \"read\", \"update\", \"list\"]\n}\npath \"kv/metadata/demo/*\" {\n  capabilities = [\"read\", \"list\"]\n}"}' > /dev/null
echo -e "${G}Policy created${N}"

# Kubernetes role
echo -e "${Y}Creating K8s role...${N}"
bao_api --fail -X POST "${BAO_URL}/v1/auth/kubernetes/role/demo-app" \
  -d '{
    "bound_service_account_names": ["demo-app"],
    "bound_service_account_namespaces": ["default"],
    "policies": ["demo-app"],
    "ttl": "1h"
  }' > /dev/null
echo -e "${G}K8s role created${N}"

SECRET_URL="${BAO_URL}/v1/kv/data/demo/config"
SECRET_STATUS=$(bao_api -o /dev/null -w '%{http_code}' "$SECRET_URL")
case "$SECRET_STATUS" in
  200) echo -e "${G}Existing demo secrets kept${N}" ;;
  404)
    bao_api --fail -X POST "$SECRET_URL" \
      -d '{"options":{"cas":0},"data":{"message":"Hello from OpenBao","api_key":"sk-demo-1234567890"}}' > /dev/null
    echo -e "${G}Demo secrets created${N}"
    ;;
  *)
    echo "Could not check the demo secret (HTTP $SECRET_STATUS)." >&2
    exit 1
    ;;
esac

echo ""
echo -e "${G}Demo app OpenBao setup complete!${N}"
