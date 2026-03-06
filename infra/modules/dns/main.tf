terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

# =============================================================================
# DNS Module - Public or Private Zone (optional)
# =============================================================================

variable "name_prefix" { type = string }

variable "vpc_id" {
  type    = string
  default = ""
}

variable "create_dns" {
  type    = bool
  default = false
}

variable "region" {
  type    = string
  default = "eu-de"
}

variable "zone_name" {
  type    = string
  default = "cluster.internal."
}

variable "zone_type" {
  type    = string
  default = "public"
  validation {
    condition     = contains(["public", "private"], var.zone_type)
    error_message = "Must be public or private."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "opentelekomcloud_dns_zone_v2" "this" {
  count = var.create_dns ? 1 : 0

  name        = var.zone_name
  description = "DNS zone for ${var.name_prefix}"
  type        = var.zone_type
  email       = "admin@${trimsuffix(var.zone_name, ".")}"
  ttl         = 300
  tags        = var.tags

  dynamic "router" {
    for_each = var.zone_type == "private" ? [1] : []
    content {
      router_id     = var.vpc_id
      router_region = var.region
    }
  }
}

output "zone_id" {
  value = var.create_dns ? opentelekomcloud_dns_zone_v2.this[0].id : null
}

output "zone_name" {
  value = var.create_dns ? var.zone_name : null
}
