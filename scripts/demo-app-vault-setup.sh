#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="vault"

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'

# Read defaults from tfvars
TFVARS="apps/terraform.tfvars"
DEFAULT_HOSTNAME=""
if [ -f "$TFVARS" ]; then
  VAULT_HOST=$(grep 'vault_hostname' "$TFVARS" 2>/dev/null | cut -d'"' -f2 || true)
fi

# Try to get zone from infra tfvars
INFRA_TFVARS="infra/terraform.tfvars"
if [ -f "$INFRA_TFVARS" ]; then
  ZONE=$(grep 'dns_zone_name' "$INFRA_TFVARS" 2>/dev/null | cut -d'"' -f2 | sed 's/\.$//' || true)
fi

if [ -n "${VAULT_HOST:-}" ] && [ -n "${ZONE:-}" ]; then
  DEFAULT_HOSTNAME="${VAULT_HOST}.${ZONE}"
fi

echo -e "${Y}🔧 Demo App Vault Setup${N}"
echo ""

# Vault address
if [ -n "$DEFAULT_HOSTNAME" ]; then
  read -rp "Vault URL [https://${DEFAULT_HOSTNAME}]: " VAULT_URL
  VAULT_URL=${VAULT_URL:-"https://${DEFAULT_HOSTNAME}"}
else
  read -rp "Vault URL: " VAULT_URL
fi

if [ -z "$VAULT_URL" ]; then
  echo -e "${R}Vault URL required${N}"
  exit 1
fi

read -rp "Admin username [admin]: " VAULT_USER
VAULT_USER=${VAULT_USER:-admin}
read -rsp "Admin password: " VAULT_PASS
echo ""

# Login
echo -e "${Y}Logging in...${N}"
TOKEN=$(curl -sf -X POST "${VAULT_URL}/v1/auth/userpass/login/${VAULT_USER}" \
  -d "{\"password\":\"${VAULT_PASS}\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

if [ -z "$TOKEN" ]; then
  echo -e "${R}Login failed${N}"
  exit 1
fi

echo -e "${G}Logged in${N}"

# Policy
echo -e "${Y}Creating policy...${N}"
curl -sf -X PUT "${VAULT_URL}/v1/sys/policies/acl/demo-app" \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"policy":"path \"kv/data/demo/*\" {\n  capabilities = [\"create\", \"read\", \"update\", \"list\"]\n}"}' > /dev/null
echo -e "${G}Policy created${N}"

# Kubernetes role
echo -e "${Y}Creating K8s role...${N}"
curl -sf -X POST "${VAULT_URL}/v1/auth/kubernetes/role/demo-app" \
  -H "X-Vault-Token: $TOKEN" \
  -d '{
    "bound_service_account_names": ["demo-app"],
    "bound_service_account_namespaces": ["default"],
    "policies": ["demo-app"],
    "ttl": "1h"
  }' > /dev/null
echo -e "${G}K8s role created${N}"

# Seed secrets
echo -e "${Y}Seeding demo secrets...${N}"
curl -sf -X POST "${VAULT_URL}/v1/kv/data/demo/config" \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"data":{"message":"Hello from Vault","api_key":"sk-demo-1234567890"}}' > /dev/null
echo -e "${G}Demo secrets created${N}"

echo ""
echo -e "${G}Demo app Vault setup complete!${N}"
