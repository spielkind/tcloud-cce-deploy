#!/usr/bin/env bash
# Configures OpenBao for the demo app (policy, Kubernetes auth role, demo secret).
# Works for both OpenBao modes; settings are read from `tofu output` in workloads/.
#
#   cce mode: run scripts/openbao-init.sh first; log in with the userpass admin.
#   vm mode:  run `sudo bao-init.sh` on the bastion first; log in with its AppRole
#             (BAO_ROLE_ID/BAO_SECRET_ID). This script also enables KV v2 and
#             configures the Kubernetes auth method, because OpenBao runs outside
#             the cluster and needs the public API endpoint, CA and a token reviewer JWT.
#
# Optional environment:
#   BAO_ADDR                    OpenBao URL (default: workloads output openbao_url)
#   BAO_TOKEN                   use an existing token instead of logging in
#   BAO_ROLE_ID, BAO_SECRET_ID  AppRole login (vm mode bastion AppRole "workloads-tofu")
#   BAO_CACERT                  CA file for a privately signed OpenBao certificate
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKLOADS_DIR="$REPO_DIR/workloads"
CURL_ARGS=(--silent --show-error --connect-timeout 5 --max-time 20)
if [ -n "${BAO_CACERT:-}" ]; then
  CURL_ARGS+=(--cacert "$BAO_CACERT")
fi
for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 1; }
done

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'

tf_output() {
  command -v tofu >/dev/null || return 1
  tofu -chdir="$WORKLOADS_DIR" output -raw "$1" 2>/dev/null
}

echo -e "${Y}Demo App OpenBao Setup${N}"
echo ""

MODE=$(tf_output openbao_mode || true)
case "$MODE" in
  cce|vm) echo "OpenBao mode: $MODE" ;;
  *)
    read -rp "OpenBao mode (cce/vm) [cce]: " MODE
    MODE=${MODE:-cce}
    ;;
esac
if [[ "$MODE" != "cce" && "$MODE" != "vm" ]]; then
  echo -e "${R}Unsupported OpenBao mode: $MODE${N}" >&2
  exit 1
fi

BAO_URL=${BAO_ADDR:-$(tf_output openbao_url || true)}
if [ -n "$BAO_URL" ]; then
  echo "OpenBao URL:  $BAO_URL"
else
  read -rp "OpenBao URL: " BAO_URL
fi
if [ -z "$BAO_URL" ]; then
  echo -e "${R}OpenBao URL required${N}" >&2
  exit 1
fi
BAO_URL=${BAO_URL%/}

if ! curl "${CURL_ARGS[@]}" --fail \
  "${BAO_URL}/v1/sys/health?standbyok=true&perfstandbyok=true" > /dev/null; then
  if [ "$MODE" = "vm" ]; then
    echo "OpenBao is not reachable or not ready. Initialize it on the bastion (sudo bao-init.sh)" >&2
    echo "and make sure your IP is in openbao_vm.api_allowed_cidrs." >&2
  else
    echo "OpenBao is not reachable or not ready. Run scripts/openbao-init.sh (initialize + unseal) first." >&2
  fi
  exit 1
fi

# Login
if [ -n "${BAO_TOKEN:-}" ]; then
  TOKEN="$BAO_TOKEN"
  echo -e "${G}Using BAO_TOKEN${N}"
elif [ -n "${BAO_ROLE_ID:-}" ] && [ -n "${BAO_SECRET_ID:-}" ]; then
  echo -e "${Y}Logging in with AppRole...${N}"
  if ! TOKEN=$(jq -n --arg r "$BAO_ROLE_ID" --arg s "$BAO_SECRET_ID" '{role_id: $r, secret_id: $s}' |
    curl "${CURL_ARGS[@]}" --fail -H 'Content-Type: application/json' \
      --data-binary @- "${BAO_URL}/v1/auth/approle/login" |
    jq -er '.auth.client_token | strings | select(length > 0)'); then
    echo -e "${R}AppRole login failed. Check BAO_ROLE_ID/BAO_SECRET_ID.${N}" >&2
    exit 1
  fi
else
  if [ "$MODE" = "vm" ]; then
    echo "Hint: in vm mode export BAO_ROLE_ID/BAO_SECRET_ID printed by bao-init.sh on the bastion."
  fi
  read -rp "Admin username [admin]: " BAO_USER
  BAO_USER=${BAO_USER:-admin}
  read -rsp "Admin password: " BAO_PASS
  echo ""
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
fi

bao_api() {
  curl "${CURL_ARGS[@]}" --header @<(printf 'Authorization: Bearer %s\n' "$TOKEN") \
    -H 'Content-Type: application/json' "$@"
}

echo -e "${G}Logged in${N}"

# KV v2 and Kubernetes auth (openbao-init.sh sets these up in cce mode)
MOUNTS=$(bao_api --fail "${BAO_URL}/v1/sys/mounts")
if ! jq -e '.data["kv/"] // ."kv/"' <<< "$MOUNTS" > /dev/null; then
  echo -e "${Y}Enabling KV v2 at kv/...${N}"
  bao_api --fail -X POST "${BAO_URL}/v1/sys/mounts/kv" \
    -d '{"type":"kv","options":{"version":"2"}}' > /dev/null
fi

if [ "$MODE" = "vm" ]; then
  AUTHS=$(bao_api --fail "${BAO_URL}/v1/sys/auth")
  if ! jq -e '.data["kubernetes/"] // ."kubernetes/"' <<< "$AUTHS" > /dev/null; then
    echo -e "${Y}Enabling Kubernetes auth...${N}"
    bao_api --fail -X POST "${BAO_URL}/v1/sys/auth/kubernetes" -d '{"type":"kubernetes"}' > /dev/null
  fi

  K8S_HOST=$(tf_output openbao_kubernetes_host || true)
  K8S_CA=$(tf_output openbao_kubernetes_ca_cert || true)
  REVIEWER_JWT=$(tf_output openbao_token_reviewer_jwt || true)
  if [ -z "$K8S_HOST" ] || [ -z "$K8S_CA" ] || [ -z "$REVIEWER_JWT" ]; then
    echo -e "${R}Missing workloads outputs openbao_kubernetes_host/_ca_cert/openbao_token_reviewer_jwt.${N}" >&2
    echo "Apply workloads with create_openbao = true in vm mode first." >&2
    exit 1
  fi
  echo -e "${Y}Configuring Kubernetes auth (TokenReview via $K8S_HOST)...${N}"
  jq -n --arg host "$K8S_HOST" --arg ca "$K8S_CA" --arg jwt "$REVIEWER_JWT" \
    '{kubernetes_host: $host, kubernetes_ca_cert: $ca, token_reviewer_jwt: $jwt, disable_local_ca_jwt: true}' |
    bao_api --fail -X POST --data-binary @- "${BAO_URL}/v1/auth/kubernetes/config" > /dev/null
  unset REVIEWER_JWT
  echo -e "${G}Kubernetes auth configured${N}"
fi

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
