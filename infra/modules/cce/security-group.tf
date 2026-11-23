# Worker node security group.
#
# Ingress traffic path (shared ELB created in ingress.tf):
# - eni (CCE Turbo): the ELB forwards to pod ENI IPs:targetPort. Pod ENIs are
#   bound to the CCE-managed "<cluster>-cce-eni-*" security group, so no rule
#   on this node group is needed for ingress traffic.
# - overlay_l2 / vpc-router: the ELB forwards to node IP:NodePort. Shared ELB
#   layer-4 listeners keep the client source IP, therefore the NodePort range
#   must accept the internet when the ingress addon is enabled.
# Ports 80/443 on the nodes themselves are only needed for hostNetwork or
# hostPort workloads and are opt-in via expose_node_http_ports.
locals {
  nodeport_cidrs = length(var.nodeport_cidrs) > 0 ? var.nodeport_cidrs : (
    var.create_ingress && !local.is_turbo ? ["0.0.0.0/0"] : [var.vpc_cidr]
  )
}

resource "opentelekomcloud_networking_secgroup_v2" "this" {
  name                 = "${var.name_prefix}-sg"
  description          = "Security group for CCE worker nodes"
  delete_default_rules = true
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "egress_all" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "egress"
  ethertype         = "IPv4"
}

# Node-to-node, master-to-node and (in eni mode) pod ENI traffic: the ENI
# subnet lies inside the VPC CIDR.
resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_vpc" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = var.vpc_cidr
}

# Virtual pod CIDR exists only for overlay_l2/vpc-router clusters.
resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_pods" {
  count = local.is_turbo ? 0 : 1

  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = var.container_cidr
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_ssh" {
  for_each = toset(var.bastion_cidrs)

  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_nodeport" {
  for_each = toset(local.nodeport_cidrs)

  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = each.value
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_http" {
  for_each = var.expose_node_http_ports ? toset(["80", "443"]) : toset([])

  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "0.0.0.0/0"
}
