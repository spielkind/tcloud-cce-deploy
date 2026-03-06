# =============================================================================
# HashiCorp Vault (HA with Raft storage + Injector)
# =============================================================================
resource "helm_release" "vault" {
  count            = var.create_vault ? 1 : 0
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.vault_chart_version
  namespace        = "vault"
  create_namespace = true

  # --- Server ---
  set {
    name  = "server.ha.enabled"
    value = "true"
  }

  set {
    name  = "server.ha.replicas"
    value = tostring(var.vault_replicas)
  }

  set {
    name  = "server.ha.raft.enabled"
    value = "true"
  }

  set {
    name  = "server.ha.raft.setNodeId"
    value = "true"
  }

  # Raft storage config
  set {
    name  = "server.ha.raft.config"
    value = <<-EOT
      ui = true

      listener "tcp" {
        tls_disable = 1
        address     = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "raft" {
        path = "/vault/data"
      }

      service_registration "kubernetes" {}
    EOT
  }

  # Data volume
  set {
    name  = "server.dataStorage.enabled"
    value = "true"
  }

  set {
    name  = "server.dataStorage.size"
    value = var.vault_storage_size
  }

  set {
    name  = "server.dataStorage.storageClass"
    value = "csi-disk"
  }

  # Resources
  set {
    name  = "server.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "server.resources.requests.cpu"
    value = "250m"
  }

  set {
    name  = "server.resources.limits.memory"
    value = "512Mi"
  }

  set {
    name  = "server.resources.limits.cpu"
    value = "500m"
  }

  # --- Ingress ---
  set {
    name  = "server.ingress.enabled"
    value = "true"
  }

  set {
    name  = "server.ingress.ingressClassName"
    value = "nginx"
  }

  set {
    name  = "server.ingress.annotations.cert-manager\\.io/cluster-issuer"
    value = "letsencrypt-prod"
  }

  set {
    name  = "server.ingress.hosts[0].host"
    value = "${var.vault_hostname}.${local.zone_name}"
  }

  set {
    name  = "server.ingress.hosts[0].paths[0]"
    value = "/"
  }

  set {
    name  = "server.ingress.tls[0].secretName"
    value = "vault-tls"
  }

  set {
    name  = "server.ingress.tls[0].hosts[0]"
    value = "${var.vault_hostname}.${local.zone_name}"
  }

  # --- UI ---
  set {
    name  = "ui.enabled"
    value = "true"
  }

  # --- Auto-Unseal Init Container ---
  values = local.vault_unseal_enabled ? [yamlencode({
    server = {
      extraInitContainers = [
        {
          name    = "unseal-trigger"
          image   = "curlimages/curl:8.5.0"
          command = ["/bin/sh", "/scripts/unseal.sh"]
          env = [
            { name = "IDP_ID",       value = local.workload_identity_idp },
            { name = "PROJECT_NAME", value = local.otc_project_name },
            { name = "PROJECT_ID",   value = local.fg_project_id },
            { name = "FUNCTION_URN", value = local.vault_unseal_fn_urn },
            { name = "POD_IP",       valueFrom = { fieldRef = { fieldPath = "status.podIP" } } },
          ]
          volumeMounts = [
            { name = "unseal-script", mountPath = "/scripts",                    readOnly = true },
            { name = "oidc-token",    mountPath = "/var/run/secrets/tokens",      readOnly = true },
          ]
        }
      ]
      volumes = [
        {
          name      = "unseal-script"
          configMap = { name = "vault-unseal-script" }
        },
        {
          name = "oidc-token"
          projected = {
            sources = [
              {
                serviceAccountToken = {
                  audience          = local.workload_identity_cid
                  expirationSeconds = 3600
                  path              = "oidc-token"
                }
              }
            ]
          }
        },
      ]
    }
  })] : []

  # --- Injector ---
  set {
    name  = "injector.enabled"
    value = "true"
  }

  set {
    name  = "injector.resources.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "injector.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "injector.resources.limits.memory"
    value = "256Mi"
  }

  set {
    name  = "injector.resources.limits.cpu"
    value = "250m"
  }

  depends_on = [helm_release.cluster_issuer]
}

# =============================================================================
# Vault Auto-Unseal Init Container
# =============================================================================
# Calls FunctionGraph async on every pod start to trigger unseal.
# The FG function waits a few seconds, then reads keys from OBS,
# decrypts via KMS, and unseals this Vault pod.
# =============================================================================

locals {
  vault_unseal_fn_urn     = try(local.infra.vault_unseal_function_urn, "")
  workload_identity_idp   = try(local.infra.workload_identity_provider_id, "")
  workload_identity_cid   = try(local.infra.workload_identity_client_id, "")
  vault_unseal_enabled    = local.vault_unseal_fn_urn != "" && local.workload_identity_idp != ""
  otc_project_name        = var.otc_project_name
  fg_project_id           = try(local.vault_unseal_fn_urn != "" ? regex(":(\\w+):function:", local.vault_unseal_fn_urn)[0] : "", "")
}

resource "kubernetes_config_map_v1" "vault_unseal_script" {
  count = var.create_vault && local.vault_unseal_enabled ? 1 : 0

  metadata {
    name      = "vault-unseal-script"
    namespace = "vault"
  }

  data = {
    "unseal.sh" = <<-SCRIPT
      #!/bin/sh
      set -e

      # Read OIDC token from projected volume
      OIDC_TOKEN=$(cat /var/run/secrets/tokens/oidc-token)

      # Exchange OIDC token for IAM token (token is in X-Subject-Token response header)
      HEADER_FILE=$(mktemp)
      HTTP_CODE=$(curl -s -w "%%{http_code}" -o /dev/null -D "$HEADER_FILE" \
        -X POST "https://iam.eu-de.otc.t-systems.com/v3.0/OS-AUTH/id-token/tokens" \
        -H "Content-Type: application/json" \
        -H "X-Idp-Id: $IDP_ID" \
        -d '{"auth":{"id_token":{"id":"'"$OIDC_TOKEN"'"},"scope":{"project":{"name":"'"$PROJECT_NAME"'"}}}}')

      IAM_TOKEN=$(grep -i "X-Subject-Token" "$HEADER_FILE" | awk '{print $2}' | tr -d '\r\n')
      rm -f "$HEADER_FILE"

      if [ -z "$IAM_TOKEN" ]; then
        echo "WARNING: Could not get IAM token — Vault may need manual unseal"
        exit 0
      fi

      echo "Got IAM token, invoking FunctionGraph async..."

      # Get own pod IP
      POD_IP=$${POD_IP:-$(hostname -i)}

      # Invoke FunctionGraph async (separate endpoint, not headers)
      curl -s -o /dev/null -w "FG invoke: HTTP %%{http_code}\n" \
        -X POST "https://functiongraph.eu-de.otc.t-systems.com/v2/$PROJECT_ID/fgs/functions/$FUNCTION_URN/invocations-async" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Token: $IAM_TOKEN" \
        -d '{"vault_addr":"http://'"$POD_IP"':8200"}'

      echo "Unseal request sent (async)"
    SCRIPT
  }

  
}
