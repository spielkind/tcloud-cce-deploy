#!/usr/bin/env bash
# Initializes the in-cluster OpenBao (openbao_mode = "cce" only): init, unseal,
# Raft join, KV v2 + userpass + Kubernetes auth, root token revocation and the
# optional KMS-encrypted upload of the unseal keys for the auto-unseal sidecar.
#
# VM mode (openbao_mode = "vm") is NOT handled here: SSH to the bastion and run
# `sudo bao-init.sh` (KMS auto-unseal, AppRole, snapshots), then
# scripts/demo-app-openbao-setup.sh.
set -euo pipefail
umask 077

NAMESPACE="openbao"
THRESHOLD=3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib-openbao-target.sh
source "$SCRIPT_DIR/lib-openbao-target.sh"

# Colors
G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'

echo -e "${Y}OpenBao Initial Setup (cce mode)${N}"
echo ""

# Cluster from the infra state of TF_VAR_environment; a KUBECONFIG for another cluster is refused.
openbao_select_target "$SCRIPT_DIR"

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
if ! kubectl --request-timeout=15s get --raw /readyz > /dev/null 2>&1; then
  echo "Cannot reach the Kubernetes API at ${SERVER:-<unknown>} (KUBECONFIG=$KUBECONFIG)." >&2
  exit 1
fi
echo "Cluster: $SERVER"

kube() {
  kubectl -n "$NAMESPACE" "$@"
}

REPLICAS=$(kube --request-timeout=15s get statefulset openbao -o json |
  jq -er '.spec.replicas | select(type == "number" and . >= 1 and floor == .)')
kube --request-timeout=15s get --raw "/api/v1/namespaces/$NAMESPACE/pods/openbao-0" > /dev/null
# Normalize OpenBao's expected sealed exit code inside the pod so kubectl stays quiet.
if ! STATUS=$(kube --request-timeout=15s exec openbao-0 -c openbao -- \
  sh -c 'bao status -format=json || [ "$?" -eq 2 ]') ||
   ! jq -e 'type == "object" and (.initialized | type == "boolean")' <<< "$STATUS" > /dev/null; then
  echo "Could not determine OpenBao initialization status; stopping." >&2
  exit 1
fi
if jq -e '.initialized' <<< "$STATUS" > /dev/null; then
  echo -e "${R}OpenBao is already initialized; use its existing keys.${N}" >&2
  exit 1
fi

# ============================================================
# Step 1: Initialize
# ============================================================
echo -e "${Y}Step 1/6: Initializing...${N}"
KEY_FILE=$(mktemp ./openbao.keys.XXXXXX)
INIT_FILE="${KEY_FILE}.json"
# Persist the raw response before parsing or running another OpenBao command.
if ! (set -o noclobber; kube exec openbao-0 -c openbao -- bao operator init \
  -key-shares=5 -key-threshold="$THRESHOLD" -format=json > "$INIT_FILE"); then
  echo "Init did not return successfully. Check OpenBao status and preserve $INIT_FILE before retrying." >&2
  exit 1
fi

# Environment + cluster ID bind the key file to this cluster (checked by upload-unseal-keys.py).
jq -er --arg env "$TF_VAR_environment" --arg cluster "$CLUSTER_ID" '
  select((.root_token | type == "string" and length > 0) and
    (.unseal_keys_b64 | type == "array" and length == 5 and all(.[]; type == "string" and length > 0)))
  | "Environment: \($env)", "CCE Cluster ID: \($cluster)",
    (.unseal_keys_b64 | to_entries[] | "Unseal Key \(.key + 1): \(.value)"), "Root Token: \(.root_token)"
' "$INIT_FILE" > "$KEY_FILE" || {
  echo "Could not parse init response; preserve $INIT_FILE." >&2
  exit 1
}
echo "Keys saved to $KEY_FILE. Copy them to your password manager."
ROOT_TOKEN=$(jq -er '.root_token' "$INIT_FILE")
KEYS=()
while IFS= read -r key; do
  KEYS+=("$key")
done < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
if [[ ${#KEYS[@]} -ne 5 ]]; then
  echo "Could not load unseal keys; preserve $KEY_FILE and $INIT_FILE." >&2
  exit 1
fi
rm -f -- "$INIT_FILE"

echo -e "${G}Initialized${N}"

# ============================================================
# Step 2: Unseal openbao-0
# ============================================================
echo -e "${Y}Step 2/6: Unsealing openbao-0...${N}"
# Shares go via stdin, never as exec arguments (those can end up in Kubernetes audit logs).
unseal_pod() {
  local i
  for ((i = 0; i < THRESHOLD; i++)); do
    printf '%s' "${KEYS[$i]}" | kube exec -i "$1" -c openbao -- bao write sys/unseal key=- > /dev/null
  done
}
unseal_pod openbao-0
echo -e "${G}openbao-0 unsealed${N}"

# ============================================================
# Step 3: Join + unseal peers
# ============================================================
echo -e "${Y}Step 3/6: Joining + unsealing peers...${N}"
# With podManagementPolicy=OrderedReady a peer pod is only created once the
# previous one is ready (unsealed), so wait for each peer's container first.
wait_for_pod() {
  local pod=$1 deadline=$((SECONDS + 600))
  until [[ -n "$(kube get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="openbao")].state.running}' 2>/dev/null)" ]]; do
    if ((SECONDS > deadline)); then
      echo "$pod did not start within 10 minutes. Keys are in $KEY_FILE; join and unseal it manually." >&2
      exit 1
    fi
    sleep 5
  done
}
for ((r = 1; r < REPLICAS; r++)); do
  echo "Waiting for openbao-$r..."
  wait_for_pod "openbao-$r"
  kube exec "openbao-$r" -c openbao -- bao operator raft join \
    http://openbao-0.openbao-internal:8200 > /dev/null
  unseal_pod "openbao-$r"
  echo -e "${G}openbao-${r} joined and unsealed${N}"
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

# shellcheck disable=SC2016 # Variable expansion belongs to the shell in the pod.
printf '%s\n' "$ROOT_TOKEN" "$ADMIN_USER" "$ADMIN_PASS" | kube exec -i openbao-0 -c openbao -- sh -ec '
  export BAO_ADDR=http://127.0.0.1:8200
  IFS= read -r BAO_TOKEN
  IFS= read -r admin_user
  IFS= read -r admin_pass
  export BAO_TOKEN

  bao secrets enable -version=2 kv > /dev/null
  bao policy write admin - <<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  bao auth enable userpass > /dev/null
  printf "%s" "$admin_pass" | bao write "auth/userpass/users/$admin_user" password=- policies=admin > /dev/null

  bao auth enable kubernetes > /dev/null
  bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc > /dev/null

  bao token revoke -self > /dev/null
'
echo -e "${G}KV v2, userpass, kubernetes auth configured${N}"
echo -e "${G}Root token revoked${N}"

# ============================================================
# Step 5: Remind users about the saved keys
# ============================================================
echo -e "${Y}Step 5/6: Keys are saved to $KEY_FILE.${N}"

# ============================================================
# Step 6: Store unseal keys for the auto-unseal sidecar (KMS ciphertext → Secret)
# ============================================================
UPLOAD_SCRIPT="$SCRIPT_DIR/upload-unseal-keys.py"
if [ -f "$UPLOAD_SCRIPT" ]; then
  echo ""
  read -rp "Store unseal keys for auto-unseal (KMS encrypted, Secret openbao-unseal-keys)? [Y/n]: " UPLOAD_CONFIRM
  UPLOAD_CONFIRM=${UPLOAD_CONFIRM:-Y}
  if [[ "$UPLOAD_CONFIRM" =~ ^[Yy] ]]; then
    echo -e "${Y}Step 6/6: Uploading unseal keys...${N}"
    if python3 "$UPLOAD_SCRIPT" "$KEY_FILE"; then
      echo -e "${G}Unseal keys encrypted and stored for auto-unseal${N}"
    else
      echo -e "${R}Upload failed — you can retry manually:${N}"
      echo "  python3 $UPLOAD_SCRIPT $KEY_FILE"
    fi
  else
    echo -e "${Y}Skipping upload. You can upload later:${N}"
    echo "  python3 $UPLOAD_SCRIPT $KEY_FILE"
  fi
else
  echo -e "${Y}upload-unseal-keys.py not found, skipping auto-unseal setup${N}"
fi

echo ""
echo -e "${G}OpenBao is ready!${N}"
echo ""
echo "  UI:       $(tofu -chdir="$SCRIPT_DIR/../workloads" output -raw openbao_url 2>/dev/null || echo "https://openbao.<your-zone>")"
echo "  Login:    Username → $ADMIN_USER"
echo "  Keys:     saved to $KEY_FILE"
echo ""
echo -e "${Y} Copy keys to your password manager, then: rm ${KEY_FILE}${N}"
