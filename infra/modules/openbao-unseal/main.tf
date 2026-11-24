terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "name_prefix" { type = string }
variable "create_openbao_unseal" {
  type    = bool
  default = false
}
variable "namespace" {
  description = "Kubernetes namespace of the OpenBao server"
  type        = string
  default     = "openbao"
}
variable "service_account" {
  description = "ServiceAccount of the OpenBao server pods"
  type        = string
  default     = "openbao"
}
variable "tags" {
  type    = map(string)
  default = {}
}

# =============================================================================
# KMS key for the OpenBao unseal keys
# The auto-unseal sidecar in each OpenBao pod decrypts the ciphertext (Kubernetes
# Secret openbao-unseal-keys) with this key and unseals via localhost.
# =============================================================================
# Deleted KMS keys stay pending (with their alias) for 7 days, so the alias gets
# a random suffix to allow destroy + redeploy within that window.
resource "random_id" "kms_alias" {
  count       = var.create_openbao_unseal ? 1 : 0
  byte_length = 3
}

resource "opentelekomcloud_kms_key_v1" "openbao" {
  count = var.create_openbao_unseal ? 1 : 0

  key_alias       = "${var.name_prefix}-openbao-unseal-${random_id.kms_alias[0].hex}"
  key_description = "Encrypts the OpenBao unseal keys (Secret openbao-unseal-keys)"
  pending_days    = 7
  is_enabled      = true
  tags            = var.tags
}

# =============================================================================
# Custom KMS policy, granted to the OpenBao ServiceAccount via workload identity.
# Resource-scoped: only the unseal key, not every KMS key in the project.
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "kms_decrypt" {
  count = var.create_openbao_unseal ? 1 : 0

  description   = "Decrypt OpenBao unseal keys (only the unseal KMS key)"
  display_name  = "${var.name_prefix}-kms-decrypt"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "kms:cmk:get",
      "kms:cmk:crypto",
    ]
    resource = ["kms:::KeyId:${opentelekomcloud_kms_key_v1.openbao[0].id}"]
  }
}

# =============================================================================
# Outputs
# =============================================================================
output "kms_key_id" {
  description = "KMS key ID for OpenBao unseal encryption"
  value       = var.create_openbao_unseal ? opentelekomcloud_kms_key_v1.openbao[0].id : ""
}

output "workload" {
  description = "Workload identity definition for OpenBao (namespace, SA, role IDs)"
  value = var.create_openbao_unseal ? {
    namespace       = var.namespace
    service_account = var.service_account
    role_ids        = [opentelekomcloud_identity_role_v3.kms_decrypt[0].id]
  } : null
}
