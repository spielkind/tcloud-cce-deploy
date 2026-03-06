terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "organization" {
  type = string
}

resource "opentelekomcloud_swr_organization_v2" "this" {
  name = var.organization
}

output "organization" {
  value = opentelekomcloud_swr_organization_v2.this.name
}

output "endpoint" {
  value = "swr.eu-de.otc.t-systems.com"
}
