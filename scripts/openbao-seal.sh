#!/usr/bin/env bash
# Deliberately seal the in-cluster OpenBao (cce mode) and keep it sealed.
#
# The auto-unseal sidecar re-unseals a sealed server as long as the Secret
# openbao-unseal-keys is mounted. Deleting the Secret reaches the pods only
# after the kubelet sync (up to ~1-2 min) and an unseal may be in progress, so
# this script waits until EVERY sidecar no longer sees the key file before it
# seals, then verifies that all servers stay sealed.
#
# Before running: keep a copy of the unseal keys (openbao.keys.* file); to
# resume auto-unseal later run scripts/upload-unseal-keys.py with it.
#
# Usage: TF_VAR_environment=dev TF_VAR_otc_project_name=... BAO_TOKEN=<token with sys/seal> ./scripts/openbao-seal.sh
set -euo pipefail

NAMESPACE="openbao"
SECRET="openbao-unseal-keys"
TIMEOUT=${SEAL_WAIT_TIMEOUT:-300}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib-openbao-target.sh
source "$SCRIPT_DIR/lib-openbao-target.sh"

: "${BAO_TOKEN:?Set BAO_TOKEN to a token allowed to call sys/seal}"
openbao_select_target "$SCRIPT_DIR"
kube() { kubectl -n "$NAMESPACE" --request-timeout=15s "$@"; }

PODS=()
while IFS= read -r pod; do
  [[ -n "$pod" ]] && PODS+=("$pod")
done < <(kube get pods -l app.kubernetes.io/name=openbao,component=server -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ ${#PODS[@]} -gt 0 ]] || { echo "No OpenBao server pods found." >&2; exit 1; }
echo "Cluster $CLUSTER_ID ($TF_VAR_environment), pods: ${PODS[*]}"
read -rp "Seal OpenBao and pause auto-unseal (deletes Secret $SECRET)? Type 'seal': " CONFIRM
[[ "$CONFIRM" == seal ]] || { echo "Aborted."; exit 1; }

echo "1/3 Deleting Secret $SECRET (auto-unseal pauses once all pods see it)..."
kube delete secret "$SECRET" --ignore-not-found

echo "2/3 Waiting until no sidecar sees the key file (timeout ${TIMEOUT}s)..."
deadline=$((SECONDS + TIMEOUT))
for pod in "${PODS[@]}"; do
  # "absent" only from a running sidecar that no longer sees the file; exec errors count as not paused.
  until [[ "$(kube exec "$pod" -c auto-unseal -- python3 -c \
      'import os; print("present" if os.path.exists("/unseal-keys/keys.enc") else "absent")' 2>/dev/null)" == absent ]]; do
    if ((SECONDS > deadline)); then
      echo "Sidecar in $pod still sees the keys after ${TIMEOUT}s; nothing sealed. Retry later." >&2
      exit 1
    fi
    sleep 5
  done
  echo "  $pod: auto-unseal paused"
done

echo "3/3 Sealing (until every running server reports sealed=true, timeout ${TIMEOUT}s)..."
# Only the active node can be sealed via the API; a standby is sealed by
# restarting it (with the Secret gone it comes back sealed and stays sealed).
# Sealing the active node moves leadership to a standby, so repeat until done.
# StatefulSet OrderedReady may hold back recreated pods while earlier ordinals
# are sealed (not ready); a pod that is not running serves nothing.
pod_sealed() {
  # shellcheck disable=SC2016 # expanded inside the pod
  kube exec "$1" -c openbao -- sh -c 'bao status -format=json || [ "$?" -eq 2 ]' 2>/dev/null | jq -r 'if (.sealed | type) == "boolean" then .sealed else empty end'
}
deadline=$((SECONDS + TIMEOUT))
while :; do
  open=0
  for pod in "${PODS[@]}"; do
    # Only a confirmed NotFound or a Pending pod (no running server) counts as not serving;
    # API errors and unknown phases keep the loop going and fail at the deadline.
    if ! phase=$(kube get pod "$pod" -o jsonpath='{.status.phase}' 2>"$OPENBAO_TMP/err"); then
      if grep -q NotFound "$OPENBAO_TMP/err"; then
        echo "  $pod: absent (not recreated yet) — serves nothing"
      else
        open=1; echo "  $pod: API error, retrying"
      fi
      continue
    fi
    case "$phase" in
      Running) ;;
      Pending) echo "  $pod: pending — serves nothing"; continue ;;
      *) open=1; echo "  $pod: phase '${phase:-?}', retrying"; continue ;;
    esac
    case "$(pod_sealed "$pod")" in
      true) echo "  $pod: sealed" ;;
      false)
        open=1
        # Token via stdin into the environment of the bao CLI, not as an exec argument.
        # shellcheck disable=SC2016 # expanded inside the pod
        if printf '%s' "$BAO_TOKEN" | kube exec -i "$pod" -c openbao -- sh -c 'BAO_TOKEN=$(cat) bao operator seal' >/dev/null 2>&1; then
          echo "  $pod: sealed via API (was active)"
        else
          echo "  $pod: standby — restarting it sealed"
          kube delete pod "$pod" --wait=false >/dev/null
        fi
        ;;
      *) open=1; echo "  $pod: status unknown (starting?)" ;;
    esac
  done
  if ((open == 0)); then
    echo "OpenBao is sealed; auto-unseal stays paused until scripts/upload-unseal-keys.py runs again."
    exit 0
  fi
  if ((SECONDS > deadline)); then
    echo "Not every server reports sealed after ${TIMEOUT}s; check 'kubectl -n $NAMESPACE get pods' and repeat." >&2
    exit 1
  fi
  sleep 10
done
