#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="vault"
KEY_FILE="vault.keys"
REPLICAS=3
THRESHOLD=3

# Colors
G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'

echo -e "${Y}Vault Initial Setup${N}"
echo ""

# Check kubectl
command -v kubectl >/dev/null || { echo -e "${R}kubectl not found${N}"; exit 1; }

# Check if already initialized
if kubectl exec -n $NAMESPACE vault-0 -- vault status 2>&1 | grep -q "Initialized.*true"; then
  echo -e "${R}Vault is already initialized${N}"
  exit 1
fi

# ============================================================
# Step 1: Initialize
# ============================================================
echo -e "${Y}Step 1/6: Initializing...${N}"
INIT_OUT=$(kubectl exec -n $NAMESPACE vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=$THRESHOLD -format=json)

ROOT_TOKEN=$(echo "$INIT_OUT" | jq -r '.root_token')
readarray -t KEYS < <(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[]')

if [ -z "$ROOT_TOKEN" ] || [ ${#KEYS[@]} -ne 5 ]; then
  echo -e "${R}Init failed${N}"
  echo "$INIT_OUT"
  exit 1
fi

echo -e "${G}Initialized${N}"

# ============================================================
# Step 2: Unseal vault-0
# ============================================================
echo -e "${Y}Step 2/6: Unsealing vault-0...${N}"
for i in 0 1 2; do
  kubectl exec -n $NAMESPACE vault-0 -- vault operator unseal "${KEYS[$i]}" > /dev/null
done
echo -e "${G}vault-0 unsealed${N}"

# ============================================================
# Step 3: Join + unseal peers
# ============================================================
echo -e "${Y}Step 3/6: Joining + unsealing peers...${N}"
for r in $(seq 1 $((REPLICAS - 1))); do
  kubectl exec -n $NAMESPACE vault-${r} -- vault operator raft join \
    http://vault-0.vault-internal:8200 > /dev/null
  for i in 0 1 2; do
    kubectl exec -n $NAMESPACE vault-${r} -- vault operator unseal "${KEYS[$i]}" > /dev/null
  done
  echo -e "${G}vault-${r} joined and unsealed${N}"
done

# ============================================================
# Step 4: Configure
# ============================================================
echo -e "${Y}Step 4/6: Configuring...${N}"

read -rp "Admin username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -rsp "Admin password: " ADMIN_PASS
echo ""

if [ -z "$ADMIN_PASS" ]; then
  echo -e "${R}Password cannot be empty${N}"
  exit 1
fi

kubectl exec -n $NAMESPACE vault-0 -- sh -c "
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login $ROOT_TOKEN > /dev/null 2>&1

  vault secrets enable -version=2 kv > /dev/null 2>&1
  vault policy write admin - <<EOF
path \"*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"]
}
EOF

  vault auth enable userpass > /dev/null 2>&1
  vault write auth/userpass/users/$ADMIN_USER password=\"$ADMIN_PASS\" policies=admin > /dev/null

  vault auth enable kubernetes > /dev/null 2>&1
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc > /dev/null

  vault token revoke -self > /dev/null 2>&1
"
echo -e "${G}KV v2, userpass, kubernetes auth configured${N}"
echo -e "${G}Root token revoked${N}"

# ============================================================
# Step 5: Save keys + done
# ============================================================
cat > "$KEY_FILE" << KEYEOF
# Vault Unseal Keys — KEEP SAFE, DO NOT COMMIT
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Unseal Key 1: ${KEYS[0]}
Unseal Key 2: ${KEYS[1]}
Unseal Key 3: ${KEYS[2]}
Unseal Key 4: ${KEYS[3]}
Unseal Key 5: ${KEYS[4]}

Root Token: ${ROOT_TOKEN}

Admin User: ${ADMIN_USER}
Admin Password: ${ADMIN_PASS}

# After setup, copy these to your password manager
# and delete this file: rm vault.keys
KEYEOF
chmod 600 "$KEY_FILE"

# ============================================================
# Step 6: Upload unseal keys (KMS encrypt + OBS)
# ============================================================
UPLOAD_SCRIPT="$(dirname "$0")/upload-unseal-keys.py"
if [ -f "$UPLOAD_SCRIPT" ]; then
  echo ""
  read -rp "Upload unseal keys to OBS (KMS encrypted)? [Y/n]: " UPLOAD_CONFIRM
  UPLOAD_CONFIRM=${UPLOAD_CONFIRM:-Y}
  if [[ "$UPLOAD_CONFIRM" =~ ^[Yy] ]]; then
    echo -e "${Y}Step 6/6: Uploading unseal keys...${N}"
    if python3 "$UPLOAD_SCRIPT" "$KEY_FILE"; then
      echo -e "${G}Unseal keys encrypted and uploaded to OBS${N}"
    else
      echo -e "${R}Upload failed — you can retry manually:${N}"
      echo "  python3 $UPLOAD_SCRIPT $KEY_FILE"
    fi
  else
    echo -e "${Y}Skipping upload. You can upload later:${N}"
    echo "  python3 $UPLOAD_SCRIPT $KEY_FILE"
  fi
else
  echo -e "${Y}upload-unseal-keys.py not found, skipping OBS upload${N}"
fi

echo ""
echo -e "${G}Vault is ready!${N}"
echo ""
echo "  UI:       https://<vault-hostname>.<your-zone>"
echo "  Login:    Username → $ADMIN_USER"
echo "  Keys:     saved to $KEY_FILE"
echo ""
echo -e "${Y} Copy keys to your password manager, then: rm ${KEY_FILE}${N}"
