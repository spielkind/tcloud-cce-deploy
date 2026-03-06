terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "bastion_cidrs" {
  type    = list(string)
  default = []
}

variable "container_cidr" {
  type    = string
  default = "172.16.0.0/16"
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

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_vpc" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = var.vpc_cidr
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_pods" {
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
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = "0.0.0.0/0"
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_http" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "ingress_https" {
  security_group_id = opentelekomcloud_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
}

output "security_group_id" {
  value = opentelekomcloud_networking_secgroup_v2.this.id
}
