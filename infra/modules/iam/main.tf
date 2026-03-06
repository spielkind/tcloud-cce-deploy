terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "project_name" {
  type    = string
  default = "eu-de_MIC_POC"
}

resource "opentelekomcloud_identity_agency_v3" "cce" {
  name                  = "cce_admin_trust"
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
  value = opentelekomcloud_identity_agency_v3.cce.name
}
