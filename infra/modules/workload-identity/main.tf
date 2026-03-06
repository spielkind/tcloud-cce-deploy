terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "create_workload_identity" {
  type    = bool
  default = false
}

variable "provider_url" {
  type        = string
  description = "OIDC provider URL (cluster issuer). Default: https://kubernetes.default.svc.cluster.local"
  default     = "https://kubernetes.default.svc.cluster.local"
}

variable "client_id" {
  type        = string
  description = "OIDC client ID used in projected service account token audience"
  default     = "otc-workload-identity"
}

variable "signing_key" {
  type        = string
  description = "JWKS public key JSON from: kubectl get --raw /openid/v1/jwks"
}

variable "project_id" {
  type        = string
  description = "OTC project ID for role assignment scope"
}

variable "workloads" {
  type = list(object({
    namespace       = string
    service_account = string
    role_ids        = list(string)
  }))
  description = "List of workloads with pre-resolved role IDs to assign"
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# =============================================================================
# Locals
# =============================================================================
locals {
  workload_map = var.create_workload_identity ? {
    for w in var.workloads : "${w.namespace}/${w.service_account}" => w
  } : {}

  # Flatten workload/role combinations for assignment
  role_assignments = var.create_workload_identity ? flatten([
    for wk, w in local.workload_map : [
      for idx, role_id in w.role_ids : {
        key     = "${wk}/${idx}"
        wk      = wk
        role_id = role_id
      }
    ]
  ]) : []
}

# =============================================================================
# IAM User Groups (one per workload)
# =============================================================================
resource "opentelekomcloud_identity_group_v3" "workload" {
  for_each    = local.workload_map
  name        = "${var.name_prefix}-${replace(each.key, "/", "-")}"
  description = "Workload identity for ${each.key}"
}

# =============================================================================
# Role Assignments
# =============================================================================
resource "opentelekomcloud_identity_role_assignment_v3" "workload" {
  for_each   = { for ra in local.role_assignments : ra.key => ra }
  group_id   = opentelekomcloud_identity_group_v3.workload[each.value.wk].id
  project_id = var.project_id
  role_id    = each.value.role_id
}

# =============================================================================
# Identity Provider (one per cluster, shared by all workloads)
# =============================================================================
resource "opentelekomcloud_identity_provider_v3" "workload" {
  count       = var.create_workload_identity ? 1 : 0
  name        = "${var.name_prefix}-workload-id"
  description = "CCE workload identity provider"
  enabled     = true
}

# =============================================================================
# Identity Mapping (all ServiceAccounts -> their respective IAM Groups)
# =============================================================================
resource "opentelekomcloud_identity_mapping_v3" "workload" {
  count      = var.create_workload_identity ? 1 : 0
  mapping_id = "${var.name_prefix}-workload-id"

  rules = jsonencode([
    for wk, w in local.workload_map : {
      local = [
        { user = { name = "${replace(wk, "/", "-")}-{0}" } },
        { group = { name = opentelekomcloud_identity_group_v3.workload[wk].name } }
      ]
      remote = [
        {
          type       = "sub"
          any_one_of = ["system:serviceaccount:${w.namespace}:${w.service_account}"]
        }
      ]
    }
  ])
}

# =============================================================================
# Identity Protocol (OIDC)
# =============================================================================
resource "opentelekomcloud_identity_protocol_v3" "workload" {
  count       = var.create_workload_identity ? 1 : 0
  protocol    = "oidc"
  provider_id = opentelekomcloud_identity_provider_v3.workload[0].id
  mapping_id  = opentelekomcloud_identity_mapping_v3.workload[0].mapping_id

  access_config {
    access_type  = "program"
    provider_url = var.provider_url
    client_id    = var.client_id
    signing_key  = var.signing_key
  }
}

# =============================================================================
# Outputs
# =============================================================================
output "provider_id" {
  description = "Identity provider ID (use as X-Idp-Id header)"
  value       = var.create_workload_identity ? opentelekomcloud_identity_provider_v3.workload[0].id : ""
}

output "client_id" {
  description = "OIDC client ID (use as audience in projected volume)"
  value       = var.client_id
}

output "group_names" {
  description = "IAM group names per workload"
  value       = { for wk, g in opentelekomcloud_identity_group_v3.workload : wk => g.name }
}
