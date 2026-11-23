# =============================================================================
# VPC + Subnet
# =============================================================================
resource "opentelekomcloud_vpc_v1" "this" {
  name = "${var.name_prefix}-openbao-vpc"
  cidr = var.vpc_cidr
  tags = var.tags
}

resource "opentelekomcloud_vpc_subnet_v1" "this" {
  name       = "${var.name_prefix}-openbao-subnet"
  vpc_id     = opentelekomcloud_vpc_v1.this.id
  cidr       = var.subnet_cidr
  gateway_ip = cidrhost(var.subnet_cidr, 1)
  dns_list   = var.vpc_dns_list
  tags       = var.tags
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "api_private" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8200
  port_range_max    = 8200
  remote_ip_prefix  = var.subnet_cidr
}
