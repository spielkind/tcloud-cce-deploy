terraform {
  required_providers {
    opentelekomcloud = {
      source                = "opentelekomcloud/opentelekomcloud"
      configuration_aliases = [opentelekomcloud.regional]
    }
    random = {
      source = "hashicorp/random"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

locals {
  node_ips        = [for i in range(length(var.availability_zones)) : cidrhost(var.subnet_cidr, 10 + i)]
  use_letsencrypt = var.enable_letsencrypt && var.tls_cert_pem == ""
  fqdn            = local.use_letsencrypt ? var.public_dns_record_name : var.tls_fqdn
}
