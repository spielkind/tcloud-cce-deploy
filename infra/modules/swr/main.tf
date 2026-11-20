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

variable "organization" {
  description = "Prefix of the SWR organization name (a random suffix is appended)"
  type        = string
}

# SWR organization names are unique across all OTC tenants, so short names
# like "test" are usually taken already.
resource "random_id" "suffix" {
  byte_length = 3
}

resource "opentelekomcloud_swr_organization_v2" "this" {
  name = "${var.organization}-${random_id.suffix.hex}"
}

output "organization" {
  value = opentelekomcloud_swr_organization_v2.this.name
}

output "endpoint" {
  value = "swr.eu-de.otc.t-systems.com"
}
