terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "eni_subnet_id" {
  description = "ENI Neutron network ID for additional SNAT rule (Turbo/Yangtse)"
  type        = string
  default     = ""
}
variable "create_eni_snat" {
  description = "Create SNAT rule for ENI subnet (must not depend on resource attributes)"
  type        = bool
  default     = false
}
variable "create_nat" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- EIP for NAT ---
resource "opentelekomcloud_vpc_eip_v1" "nat" {
  count = var.create_nat ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-nat-bw"
    size       = 100
    share_type = "PER"
  }

  tags = var.tags
}

# --- NAT Gateway ---
resource "opentelekomcloud_nat_gateway_v2" "this" {
  count = var.create_nat ? 1 : 0

  name                = "${var.name_prefix}-nat"
  spec                = "1" # small
  router_id           = var.vpc_id
  internal_network_id = var.subnet_id
  tags                = var.tags
}

# --- SNAT Rule (node subnet) ---
resource "opentelekomcloud_nat_snat_rule_v2" "this" {
  count = var.create_nat ? 1 : 0

  nat_gateway_id = opentelekomcloud_nat_gateway_v2.this[0].id
  floating_ip_id = opentelekomcloud_vpc_eip_v1.nat[0].id
  network_id     = var.subnet_id
}

# --- SNAT Rule (ENI/pod subnet, Turbo only) ---
resource "opentelekomcloud_nat_snat_rule_v2" "eni" {
  count = var.create_nat && var.create_eni_snat ? 1 : 0

  nat_gateway_id = opentelekomcloud_nat_gateway_v2.this[0].id
  floating_ip_id = opentelekomcloud_vpc_eip_v1.nat[0].id
  network_id     = var.eni_subnet_id
}

output "nat_public_ip" {
  value = var.create_nat ? opentelekomcloud_vpc_eip_v1.nat[0].publicip[0].ip_address : null
}
