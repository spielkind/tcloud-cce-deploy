terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "project_name" {
  type = string
}

variable "reuse_existing_cce_agency" {
  type    = bool
  default = false
}

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
    project = "eu-de"
    roles   = ["SWR Administrator"]
  }

  domain_roles = ["Tenant Administrator"]
}

output "agency_name" {
  value = var.reuse_existing_cce_agency ? local.cce_agency_name : opentelekomcloud_identity_agency_v3.cce[0].name
}
