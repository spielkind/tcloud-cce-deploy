# shellcheck shell=bash
# Sourced by openbao-init.sh and openbao-seal.sh: select the OpenBao (cce mode)
# cluster from the infra state of TF_VAR_environment and refuse a KUBECONFIG
# that points to another cluster. Sets CLUSTER_ID and exports KUBECONFIG (a
# temporary copy from the infra state, removed on exit).

openbao_select_target() {
  local script_dir=$1 expected actual
  case "${TF_VAR_environment:-}" in dev|prod) ;; *) echo "Set TF_VAR_environment to dev or prod." >&2; exit 1 ;; esac
  [[ -n "${TF_VAR_otc_project_name:-}" ]] || { echo "Set TF_VAR_otc_project_name." >&2; exit 1; }
  for cmd in tofu kubectl jq; do
    command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 1; }
  done
  OPENBAO_TMP=$(mktemp -d "${TMPDIR:-/tmp}/openbao-target.XXXXXX")
  trap 'rm -rf -- "$OPENBAO_TMP"' EXIT
  if ! tofu -chdir="$script_dir/../infra" output -json | jq -ce --arg env "$TF_VAR_environment" --arg project "$TF_VAR_otc_project_name" '
      if .openbao_mode.value != "cce" then error("openbao_mode is not cce (vm mode: run sudo bao-init.sh on the bastion)")
      elif .environment.value != $env then error("infra state belongs to environment \(.environment.value)")
      elif .otc_project_name.value != $project then error("infra state belongs to project \(.otc_project_name.value)")
      else {id: .cce_cluster_id.value, config: .kubeconfig.value} end |
      select(all(.[]; type == "string" and length > 0))' > "$OPENBAO_TMP/target"; then
    echo "Expected an initialized infra state for '$TF_VAR_environment' / '$TF_VAR_otc_project_name' in cce mode (tofu -chdir=infra init with this environment)." >&2
    exit 1
  fi
  # shellcheck disable=SC2034 # used by the sourcing scripts
  CLUSTER_ID=$(jq -er .id "$OPENBAO_TMP/target")
  jq -er .config "$OPENBAO_TMP/target" > "$OPENBAO_TMP/kubeconfig"
  if [[ -n "${KUBECONFIG:-}" ]]; then
    expected=$(openbao_cluster_identity "$OPENBAO_TMP/kubeconfig")
    actual=$(openbao_cluster_identity "$KUBECONFIG" 2>/dev/null || true)
    if [[ "$actual" != "$expected" ]]; then
      echo "KUBECONFIG ($KUBECONFIG) points to a different cluster than the infra state of '$TF_VAR_environment'; refusing." >&2
      exit 1
    fi
  fi
  export KUBECONFIG="$OPENBAO_TMP/kubeconfig"
}

# API endpoint + CA of the current context: identifies the cluster.
openbao_cluster_identity() {
  KUBECONFIG="$1" kubectl config view --minify --raw --flatten -o json |
    jq -ce '.clusters | select(length == 1) | .[0].cluster | [.server, ."certificate-authority-data"]
      | select(all(.[]; type == "string" and length > 0))'
}
