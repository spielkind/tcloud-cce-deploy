# =============================================================================
# NAT Gateway — outbound internet for OpenBao VMs (binary download, updates)
# =============================================================================
resource "opentelekomcloud_vpc_eip_v1" "nat" {
  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-openbao-nat-bw"
    size       = var.nat_eip_bandwidth
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_nat_gateway_v2" "this" {
  name                = "${var.name_prefix}-openbao-nat"
  spec                = "1"
  router_id           = opentelekomcloud_vpc_v1.this.id
  internal_network_id = opentelekomcloud_vpc_subnet_v1.this.id
  tags                = var.tags
}

resource "opentelekomcloud_nat_snat_rule_v2" "this" {
  nat_gateway_id = opentelekomcloud_nat_gateway_v2.this.id
  floating_ip_id = opentelekomcloud_vpc_eip_v1.nat.id
  network_id     = opentelekomcloud_vpc_subnet_v1.this.id
}

# No explicit route table entry is needed: when a public NAT gateway is attached
# to a VPC (router_id), OTC adds the 0.0.0.0/0 -> NAT gateway route to the VPC's
# default route table automatically. The SNAT rule then translates traffic from
# this subnet to the NAT EIP. The CCE NAT module (infra/modules/nat) relies on
# the same behaviour. Clients outside this VPC that the OpenBao VMs talk to
# (e.g. the CCE API for Kubernetes auth) see the NAT EIP as source address.
