terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "subnet_cidr" {
  description = "Node subnet CIDR (defaults to vpc_cidr /24 at offset 1)"
  type        = string
  default     = ""
}
variable "eni_subnet_cidr" {
  description = "ENI/pod subnet CIDR for Yangtse (empty = no ENI subnet)"
  type        = string
  default     = ""
}
variable "vpc_dns_list" {
  type    = list(string)
  default = ["100.125.4.25", "100.125.129.199"]
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  subnet_cidr       = var.subnet_cidr != "" ? var.subnet_cidr : cidrsubnet(var.vpc_cidr, 8, 1)
  create_eni_subnet = var.eni_subnet_cidr != ""
}

resource "opentelekomcloud_vpc_v1" "this" {
  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr
  tags = var.tags
}

# Node subnet
resource "opentelekomcloud_vpc_subnet_v1" "this" {
  name       = "${var.name_prefix}-subnet"
  vpc_id     = opentelekomcloud_vpc_v1.this.id
  cidr       = local.subnet_cidr
  gateway_ip = cidrhost(local.subnet_cidr, 1)
  dns_list   = var.vpc_dns_list
  tags       = var.tags
}

# ENI/pod subnet (Yangtse only)
resource "opentelekomcloud_vpc_subnet_v1" "eni" {
  count = local.create_eni_subnet ? 1 : 0

  name       = "${var.name_prefix}-eni-subnet"
  vpc_id     = opentelekomcloud_vpc_v1.this.id
  cidr       = var.eni_subnet_cidr
  gateway_ip = cidrhost(var.eni_subnet_cidr, 1)
  dns_list   = var.vpc_dns_list
  tags       = var.tags
}

output "vpc_id" {
  value = opentelekomcloud_vpc_v1.this.id
}

output "subnet_network_id" {
  value = opentelekomcloud_vpc_subnet_v1.this.network_id
}

output "subnet_id" {
  value = opentelekomcloud_vpc_subnet_v1.this.id
}

output "subnet_v2_id" {
  description = "Neutron subnet ID (for ELB v2)"
  value       = opentelekomcloud_vpc_subnet_v1.this.subnet_id
}

output "subnet_cidr" {
  description = "Node subnet CIDR"
  value       = opentelekomcloud_vpc_subnet_v1.this.cidr
}

output "eni_subnet_id" {
  description = "ENI Neutron subnet ID (empty if no ENI subnet)"
  value       = local.create_eni_subnet ? opentelekomcloud_vpc_subnet_v1.eni[0].subnet_id : ""
}

output "eni_subnet_network_id" {
  description = "ENI Neutron network ID (empty if no ENI subnet)"
  value       = local.create_eni_subnet ? opentelekomcloud_vpc_subnet_v1.eni[0].network_id : ""
}

output "eni_subnet_cidr" {
  description = "ENI subnet CIDR (falls back to node subnet)"
  value       = local.create_eni_subnet ? opentelekomcloud_vpc_subnet_v1.eni[0].cidr : opentelekomcloud_vpc_subnet_v1.this.cidr
}
