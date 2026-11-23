locals {
  cce_agency_name = "cce_admin_trust"
}

resource "opentelekomcloud_identity_agency_v3" "cce" {
  count                 = var.reuse_existing_cce_agency ? 0 : 1
  name                  = local.cce_agency_name
  description           = "Created by Terraform to auto create cce related resources"
  delegated_domain_name = "op_svc_cce"

  project_role {
    project = var.project_name
    roles   = ["Tenant Administrator"]
  }

  project_role {
    project = "MOS"
    roles   = ["Tenant Administrator"]
  }

  project_role {
    project = var.region
    roles   = ["SWR Administrator"]
  }

  domain_roles = ["Tenant Administrator"]
}

# Lets EVS use KMS keys; required for kms_id on node pool volumes.
resource "opentelekomcloud_identity_agency_v3" "evs_kms" {
  count = var.node_volume_encryption && !var.reuse_existing_evs_kms_agency ? 1 : 0

  name                  = "EVSAccessKMS"
  description           = "Allow EVS to access KMS for volume encryption"
  delegated_domain_name = "op_svc_evs"

  project_role {
    project = var.project_name
    roles   = ["KMS Administrator"]
  }
}
