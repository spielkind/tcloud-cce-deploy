# =============================================================================
# OTC DEW KMS Key for auto-unseal
# =============================================================================
resource "opentelekomcloud_kms_key_v1" "unseal" {
  count           = var.enable_auto_unseal ? 1 : 0
  key_alias       = "${var.name_prefix}-openbao-unseal-${random_id.obs_suffix.hex}"
  key_description = "Encrypts OpenBao unseal keys for auto-unseal on restart"
  is_enabled      = true
  pending_days    = 7

  # PSA Req 34: CMK must be rotated annually
  rotation_enabled  = true
  rotation_interval = 365
}

# =============================================================================
# Custom IAM Roles — least-privilege for OBS, KMS, and DNS
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "kms_decrypt" {
  description   = "KMS encrypt/decrypt for auto-unseal, snapshot tokens, and OBS SSE-KMS"
  display_name  = "${var.name_prefix}-kms-decrypt"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "kms:cmk:get",
      "kms:cmk:list",
      "kms:cmk:crypto",
      "kms:dek:create",
      "kms:dek:crypto",
    ]
  }
}

resource "opentelekomcloud_identity_role_v3" "obs_access" {
  description   = "Read and write objects in OBS buckets for snapshots, scripts, and unseal keys"
  display_name  = "${var.name_prefix}-obs-access"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "obs:bucket:ListAllMyBuckets",
      "obs:bucket:ListBucket",
      "obs:bucket:HeadBucket",
      "obs:bucket:GetBucketLocation",
      "obs:object:GetObject",
      "obs:object:PutObject",
      "obs:object:DeleteObject",
    ]
  }
}

resource "opentelekomcloud_identity_role_v3" "dns_manage" {
  count         = local.use_letsencrypt ? 1 : 0
  description   = "DNS recordset management for Let's Encrypt DNS-01 challenge"
  display_name  = "${var.name_prefix}-dns-manage"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "dns:zone:get",
      "dns:zone:list",
      "dns:recordset:get",
      "dns:recordset:list",
      "dns:recordset:create",
      "dns:recordset:delete",
      "dns:recordset:update",
    ]
  }
}

locals {
  agency_project_roles = concat(
    var.enable_auto_unseal ? [var.kms_admin_role_name] : [],
    local.use_letsencrypt ? [opentelekomcloud_identity_role_v3.dns_manage[0].display_name] : [],
    var.enable_lts_logging ? ["LTS FullAccess"] : [],
  )
}

# =============================================================================
# IAM Agency — grants OpenBao VMs + bastion access via metadata service
# =============================================================================
resource "opentelekomcloud_identity_agency_v3" "openbao" {
  name                  = "${var.name_prefix}-openbao"
  description           = "OpenBao VMs and bastion: KMS + OBS + optional LTS for snapshots, scripts, auto-unseal, and log shipping"
  delegated_domain_name = "op_svc_ecs"

  # OBS is a global service and the bucket's SSE-KMS key lives in the region
  # base project, so object access and KMS crypto are granted in all projects.
  project_role {
    all_projects = true
    roles = [
      opentelekomcloud_identity_role_v3.obs_access.display_name,
      opentelekomcloud_identity_role_v3.kms_decrypt.display_name,
    ]
  }

  dynamic "project_role" {
    for_each = length(local.agency_project_roles) > 0 ? [1] : []
    content {
      project = var.otc_project_name
      roles   = local.agency_project_roles
    }
  }
}
