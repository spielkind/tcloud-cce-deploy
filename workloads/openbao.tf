# =============================================================================
# OpenBao
#   cce mode: HA Raft server + Agent Injector in the cluster
#   vm mode:  Agent Injector only, pointing at the VM cluster from infra
# =============================================================================
locals {
  openbao_cce_enabled    = var.create_openbao && local.selected_bao_mode == "cce"
  openbao_vm_enabled     = var.create_openbao && local.selected_bao_mode == "vm"
  openbao_enabled        = local.openbao_cce_enabled || local.openbao_vm_enabled
  openbao_vm_url         = try(local.infra.openbao_vm_url, "")
  openbao_vm_ca_cert     = try(local.infra.openbao_vm_ca_cert, "")
  openbao_namespace      = "openbao"
  openbao_cce_url        = "https://${var.openbao_hostname}.${local.zone_name}"
  openbao_public_url     = local.openbao_cce_enabled ? local.openbao_cce_url : (local.openbao_vm_enabled ? local.openbao_vm_url : null)
  openbao_in_cluster_url = local.openbao_cce_enabled ? "http://openbao.${local.openbao_namespace}.svc:8200" : local.openbao_vm_url
  openbao_unseal_kms_key = try(local.infra.openbao_unseal_kms_key_id, "")
  workload_identity_idp  = try(local.infra.workload_identity_provider_id, "")
  workload_identity_cid  = try(local.infra.workload_identity_client_id, "")
  openbao_unseal_enabled = local.openbao_cce_enabled && local.openbao_unseal_kms_key != "" && local.workload_identity_idp != ""

  # Native sidecar (init container with restartPolicy Always): starts before the
  # server, runs for the pod lifetime and unseals the local server via 127.0.0.1
  # whenever it is sealed (files/openbao-auto-unseal.py).
  openbao_unseal_sidecar = {
    name          = "auto-unseal"
    image         = "python:3.12-alpine"
    restartPolicy = "Always"
    command       = ["python3", "-u", "/scripts/auto-unseal.py"]
    env = [
      { name = "IDP_ID", value = local.workload_identity_idp },
      { name = "PROJECT_NAME", value = local.otc_project_name },
      { name = "REGION", value = local.region },
      { name = "PYTHONDONTWRITEBYTECODE", value = "1" },
    ]
    volumeMounts = [
      { name = "unseal-script", mountPath = "/scripts", readOnly = true },
      { name = "oidc-token", mountPath = "/var/run/secrets/tokens", readOnly = true },
      { name = "unseal-keys", mountPath = "/unseal-keys", readOnly = true },
    ]
    resources = {
      requests = { cpu = "5m", memory = "24Mi" }
      limits   = { cpu = "100m", memory = "64Mi" }
    }
    securityContext = {
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      capabilities             = { drop = ["ALL"] }
    }
  }

  openbao_unseal_volumes = [
    {
      name      = "unseal-script"
      configMap = { name = "openbao-unseal-script" }
    },
    {
      # KMS ciphertext written by scripts/upload-unseal-keys.py (optional: the
      # pod starts without it and is unsealed manually).
      name   = "unseal-keys"
      secret = { secretName = "openbao-unseal-keys", optional = true }
    },
    {
      name = "oidc-token"
      projected = {
        sources = [{
          serviceAccountToken = {
            audience          = local.workload_identity_cid
            expirationSeconds = 3600
            path              = "oidc-token"
          }
        }]
      }
    },
  ]
}

resource "kubernetes_namespace_v1" "openbao" {
  count = local.openbao_enabled ? 1 : 0

  metadata {
    name = local.openbao_namespace
  }

  lifecycle {
    precondition {
      condition     = !local.openbao_vm_enabled || local.openbao_vm_url != ""
      error_message = "openbao_mode is vm but the infra state has no openbao_vm_url output."
    }
  }
}

resource "kubernetes_config_map_v1" "openbao_unseal_script" {
  count = local.openbao_unseal_enabled ? 1 : 0

  metadata {
    name      = "openbao-unseal-script"
    namespace = kubernetes_namespace_v1.openbao[0].metadata[0].name
  }

  data = {
    "auto-unseal.py" = file("${path.module}/files/openbao-auto-unseal.py")
  }
}

resource "helm_release" "openbao" {
  count      = local.openbao_cce_enabled ? 1 : 0
  name       = "openbao"
  repository = "https://openbao.github.io/openbao-helm"
  chart      = "openbao"
  version    = var.openbao_chart_version
  namespace  = kubernetes_namespace_v1.openbao[0].metadata[0].name

  values = [yamlencode({
    server = {
      ha = {
        enabled  = true
        replicas = var.openbao_replicas
        raft = {
          enabled   = true
          setNodeId = true
          config    = <<-EOT
            ui = true

            listener "tcp" {
              tls_disable     = 1
              address         = "[::]:8200"
              cluster_address = "[::]:8201"
            }

            storage "raft" {
              path = "/openbao/data"
            }

            service_registration "kubernetes" {}
            %{if var.openbao_audit_enabled~}

            # Declarative audit device (OpenBao >= 2.x): JSON audit entries on
            # stdout -> collected by log-agent into the cluster LTS stdout stream.
            audit "file" "stdout" {
              description = "Audit log to stdout (LTS via log-agent)"
              options = {
                file_path = "stdout"
              }
            }
            %{endif~}
          EOT
        }
      }

      dataStorage = {
        enabled      = true
        size         = var.openbao_storage_size
        storageClass = "csi-disk"
      }

      resources = {
        requests = { memory = "256Mi", cpu = "250m" }
        limits   = { memory = "512Mi", cpu = "500m" }
      }

      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        annotations = {
          "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
        }
        hosts = [{
          host  = "${var.openbao_hostname}.${local.zone_name}"
          paths = ["/"]
        }]
        tls = [{
          secretName = "openbao-tls"
          hosts      = ["${var.openbao_hostname}.${local.zone_name}"]
        }]
      }

      extraInitContainers = local.openbao_unseal_enabled ? [local.openbao_unseal_sidecar] : null
      volumes             = local.openbao_unseal_enabled ? local.openbao_unseal_volumes : null
    }

    ui = { enabled = true }

    injector = {
      enabled = true
      resources = {
        requests = { memory = "128Mi", cpu = "100m" }
        limits   = { memory = "256Mi", cpu = "250m" }
      }
    }
  })]

  depends_on = [helm_release.cluster_issuer, kubernetes_config_map_v1.openbao_unseal_script]
}

# =============================================================================
# VM mode: Agent Injector for the external OpenBao cluster
# =============================================================================
resource "helm_release" "openbao_injector" {
  count      = local.openbao_vm_enabled ? 1 : 0
  name       = "openbao"
  repository = "https://openbao.github.io/openbao-helm"
  chart      = "openbao"
  version    = var.openbao_chart_version
  namespace  = kubernetes_namespace_v1.openbao[0].metadata[0].name

  values = [yamlencode({
    global = {
      externalBaoAddr = local.openbao_vm_url
    }

    server = { enabled = false }
    ui     = { enabled = false }
    csi    = { enabled = false }

    injector = {
      enabled = true
      resources = {
        requests = { memory = "128Mi", cpu = "100m" }
        limits   = { memory = "256Mi", cpu = "250m" }
      }
      # BYO TLS only: injected agents trust this CA (Let's Encrypt is system-trusted).
      extraEnvironmentVars = local.openbao_vm_ca_cert != "" ? {
        AGENT_INJECT_VAULT_CACERT_BYTES = local.openbao_vm_ca_cert
      } : {}
    }
  })]
}

# OpenBao runs outside the cluster, so its Kubernetes auth method needs a JWT
# allowed to call the TokenReview API (system:auth-delegator). The token, the
# public API endpoint and the cluster CA are exposed as outputs and written to
# auth/kubernetes/config by scripts/demo-app-openbao-setup.sh.
resource "kubernetes_service_account_v1" "openbao_token_reviewer" {
  count = local.openbao_vm_enabled ? 1 : 0

  metadata {
    name      = "openbao-token-reviewer"
    namespace = kubernetes_namespace_v1.openbao[0].metadata[0].name
  }
}

resource "kubernetes_secret_v1" "openbao_token_reviewer" {
  count = local.openbao_vm_enabled ? 1 : 0

  metadata {
    name      = "openbao-token-reviewer"
    namespace = kubernetes_namespace_v1.openbao[0].metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.openbao_token_reviewer[0].metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "kubernetes_cluster_role_binding_v1" "openbao_token_reviewer" {
  count = local.openbao_vm_enabled ? 1 : 0

  metadata {
    name = "openbao-token-reviewer"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.openbao_token_reviewer[0].metadata[0].name
    namespace = kubernetes_namespace_v1.openbao[0].metadata[0].name
  }
}
