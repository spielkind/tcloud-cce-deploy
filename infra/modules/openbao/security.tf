# =============================================================================
# Security Group
# =============================================================================
resource "opentelekomcloud_networking_secgroup_v2" "this" {
  name        = "${var.name_prefix}-openbao-sg"
  description = "OpenBao — API (8200) and Raft cluster (8201)"
}

# ELB listeners are TCP pass-through and preserve the original client source.
# These rules permit configured CIDRs to reach backend API port 8200.
resource "opentelekomcloud_networking_secgroup_rule_v2" "api" {
  count             = length(var.api_allowed_cidrs)
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8200
  port_range_max    = 8200
  remote_ip_prefix  = var.api_allowed_cidrs[count.index]
}

# CCE NAT EIP: injected agents and workloads in CCE reach the API via SNAT.
resource "opentelekomcloud_networking_secgroup_rule_v2" "api_cce_nat" {
  count             = var.allow_cce_nat_cidr ? 1 : 0
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8200
  port_range_max    = 8200
  remote_ip_prefix  = var.cce_nat_cidr
}

# Shared ELB health checks originate from 100.125.0.0/16 (OTC ELB service
# network). Without this rule all members are marked unhealthy once the API is
# restricted to api_allowed_cidrs.
resource "opentelekomcloud_networking_secgroup_rule_v2" "elb_health_check" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8200
  port_range_max    = 8200
  remote_ip_prefix  = "100.125.0.0/16"
}

# Allow Raft replication within the private OpenBao subnet only.
resource "opentelekomcloud_networking_secgroup_rule_v2" "raft" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8201
  port_range_max    = 8201
  remote_ip_prefix  = var.subnet_cidr
}

# Allow SSH from bastion security group to OpenBao nodes
resource "opentelekomcloud_networking_secgroup_rule_v2" "ssh_from_bastion" {
  count             = var.enable_bastion ? 1 : 0
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_group_id   = opentelekomcloud_networking_secgroup_v2.bastion[0].id
}
