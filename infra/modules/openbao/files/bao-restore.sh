#!/bin/bash
# Restore an OpenBao Raft snapshot (runs on the bastion host).
#
# Usage: sudo [BAO_TOKEN=...] bao-restore.sh [--dry-run] [--yes] [SNAPSHOT]
#   SNAPSHOT   local snapshot file, or the number shown in the list (default: 1 = newest)
#   --dry-run  only list the snapshots in OBS (and the selection); change nothing
#   --yes      skip the interactive "RESTORE" confirmation (automation)
set -euo pipefail

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

DRY_RUN=false
ASSUME_YES=false
SNAP_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) SNAP_ARG="$1" ;;
  esac
  shift
done

# shellcheck source=/dev/null
source /etc/openbao/auto-unseal.env
# shellcheck source=/dev/null
source /etc/profile.d/openbao.sh
# shellcheck source=/dev/null
source /usr/local/lib/openbao/tls.sh

OBS_ENDPOINT="https://obs.${KMS_REGION}.otc.t-systems.com"
OBS_PREFIX="snapshots"

# shellcheck source=/dev/null
source /usr/local/lib/openbao/agency-creds.sh

SNAP_FILE=""
if [ -n "${SNAP_ARG}" ] && [ -f "${SNAP_ARG}" ]; then
  SNAP_FILE="${SNAP_ARG}"
  echo "Using local snapshot: ${SNAP_FILE}"
else
  echo "=== Available Raft Snapshots ==="
  SNAPSHOTS=$(aws s3 ls "s3://${OBS_BUCKET}/${OBS_PREFIX}/" \
    --endpoint-url "${OBS_ENDPOINT}" --region "${KMS_REGION}" 2>/dev/null |
    grep 'raft-snapshot-' | sort -r || true)

  if [ -z "${SNAPSHOTS}" ]; then
    echo "  No snapshots found in s3://${OBS_BUCKET}/${OBS_PREFIX}/"
    exit 1
  fi

  i=0
  declare -a SNAP_KEYS
  while IFS= read -r line; do
    SIZE=$(awk '{print $3}' <<< "${line}")
    KEY=$(awk '{print $4}' <<< "${line}")
    TS=${KEY#raft-snapshot-}
    TS=${TS%.snap}
    i=$((i + 1))
    SNAP_KEYS[i]="${KEY}"
    echo "  [${i}] ${TS}  ($(( SIZE / 1024 )) KB)"
  done <<< "${SNAPSHOTS}"
  echo ""

  if [ -n "${SNAP_ARG}" ]; then
    CHOICE="${SNAP_ARG}"
  elif [ "${DRY_RUN}" = "true" ] || [ "${ASSUME_YES}" = "true" ]; then
    CHOICE=1
  else
    read -rp "Select snapshot [1]: " CHOICE
    CHOICE=${CHOICE:-1}
  fi

  if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || [ -z "${SNAP_KEYS[CHOICE]:-}" ]; then
    echo "Invalid selection: ${CHOICE}" >&2
    exit 1
  fi
  SELECTED="${SNAP_KEYS[CHOICE]}"

  if [ "${DRY_RUN}" = "true" ]; then
    echo "Dry run: would restore s3://${OBS_BUCKET}/${OBS_PREFIX}/${SELECTED}"
    exit 0
  fi

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR}"' EXIT
  SNAP_FILE="${WORK_DIR}/${SELECTED}"
  echo "  Downloading ${SELECTED} ..."
  aws s3 cp "s3://${OBS_BUCKET}/${OBS_PREFIX}/${SELECTED}" "${SNAP_FILE}" \
    --endpoint-url "${OBS_ENDPOINT}" --region "${KMS_REGION}"
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "Dry run: would restore ${SNAP_FILE}"
  exit 0
fi

SEAL_STATUS=$(bao status -format=json 2>/dev/null || true)
IS_INIT=$(jq -r '.initialized // false' <<< "${SEAL_STATUS}" 2>/dev/null || echo "false")
IS_SEALED=$(jq -r '.sealed // true' <<< "${SEAL_STATUS}" 2>/dev/null || echo "true")
FORCE_RESTORE=false

if [ "${IS_INIT}" = "false" ]; then
  echo "OpenBao is not initialized — using disaster recovery mode"
  echo "  A temporary init+unseal will be performed before force-restoring."
  echo "  After restore, unseal keys from the ORIGINAL cluster apply."
  echo "  Targeting node directly: ${INIT_NODE}"
  FORCE_RESTORE=true
  # Target the first node directly — the ELB may route to different uninitialized
  # nodes. TLS is still verified: tls.sh sets BAO_TLS_SERVER_NAME to the FQDN.
  export BAO_ADDR="${INIT_NODE}"
elif [ -z "${BAO_TOKEN:-}" ]; then
  echo "ERROR: BAO_TOKEN must be set (token with sys/storage/raft/snapshot-force or root)" >&2
  echo "Usage: sudo BAO_TOKEN=s.xxxxx bao-restore.sh [--yes] [snapshot]" >&2
  exit 1
else
  export BAO_TOKEN
fi

SNAP_SIZE=$(stat -c%s "${SNAP_FILE}" 2>/dev/null || stat -f%z "${SNAP_FILE}")
echo ""
echo "=== Restoring Raft Snapshot ==="
echo "  File: ${SNAP_FILE}"
echo "  Size: $(( SNAP_SIZE / 1024 )) KB"
echo ""

if [ "${FORCE_RESTORE}" = "true" ]; then
  echo "  WARNING: This performs a temporary init, then force-restores the snapshot."
  echo "  The temporary keys are discarded — ORIGINAL cluster keys apply after restore."
else
  if [ "${IS_SEALED}" = "true" ]; then
    echo "  OpenBao is sealed. Attempting unseal..."
    if [ -x /usr/local/bin/bao-unseal.sh ]; then
      /usr/local/bin/bao-unseal.sh
      sleep 3
      SEAL_STATUS=$(bao status -format=json 2>/dev/null || true)
      IS_SEALED=$(jq -r '.sealed // true' <<< "${SEAL_STATUS}" 2>/dev/null || echo "true")
    fi
    if [ "${IS_SEALED}" = "true" ]; then
      echo "  ERROR: OpenBao is still sealed. Unseal manually before restoring." >&2
      exit 1
    fi
    echo "  Unseal successful."
  fi
  echo "  WARNING: This replaces the ENTIRE Raft state (all secrets, policies, auth)!"
  echo "  Data written after the snapshot was taken is lost."
fi
echo ""

if [ "${ASSUME_YES}" != "true" ]; then
  if [ ! -t 0 ]; then
    echo "Refusing to restore without a terminal; pass --yes to confirm." >&2
    exit 1
  fi
  read -rp "Type RESTORE to continue: " CONFIRM
  if [ "${CONFIRM}" != "RESTORE" ]; then
    echo "Aborted."
    exit 0
  fi
fi

if [ "${FORCE_RESTORE}" = "true" ]; then
  echo "  Performing temporary init on ${INIT_NODE}..."
  INIT_OUT=$(bao operator init -key-shares=1 -key-threshold=1 -format=json)
  TEMP_UNSEAL=$(jq -r '.unseal_keys_b64[0]' <<< "${INIT_OUT}")
  TEMP_TOKEN=$(jq -r '.root_token' <<< "${INIT_OUT}")

  echo "  Unsealing with temporary key..."
  bao operator unseal "${TEMP_UNSEAL}" > /dev/null

  # Wait for Raft leader election before restoring
  echo "  Waiting for Raft leader..."
  sleep 10

  echo "  Force-restoring snapshot..."
  BAO_TOKEN="${TEMP_TOKEN}" bao operator raft snapshot restore -force "${SNAP_FILE}"
  echo "  Force restore complete. Temporary keys are now invalid."

  INIT_IP=${INIT_NODE#https://}
  INIT_IP=${INIT_IP%:8200}
  echo ""
  echo "  Snapshot applied. Now restart the leader node to load the restored state:"
  echo ""
  echo "    ssh ubuntu@${INIT_IP} 'sudo systemctl restart openbao'"
  echo "    sleep 5 && sudo bao-unseal.sh"
  echo ""
else
  bao operator raft snapshot restore "${SNAP_FILE}"
  echo "  Restore complete. Cluster is now sealed."
  echo ""
  echo "  Re-unsealing all nodes..."
  /usr/local/bin/bao-unseal.sh
  echo ""
  echo "=== Restore complete ==="
fi
