terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "cluster_id" { type = string }
variable "node_flavor" { type = string }
variable "node_count" { type = number }
variable "node_os" { type = string }
variable "key_pair" { type = string }
variable "subnet_id" { type = string }
variable "autoscaling_enabled" {
  type    = bool
  default = false
}
variable "availability_zones" {
  type    = list(string)
  default = ["eu-de-01", "eu-de-02", "eu-de-03"]
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "opentelekomcloud_cce_node_pool_v3" "this" {
  cluster_id = var.cluster_id
  name       = "${var.name_prefix}-pool"
  flavor     = var.node_flavor
  os         = var.node_os

  initial_node_count = var.node_count
  key_pair           = var.key_pair
  subnet_id          = var.subnet_id
  availability_zone  = length(var.availability_zones) > 1 ? "random" : var.availability_zones[0]

  scale_enable             = var.autoscaling_enabled
  min_node_count           = var.autoscaling_enabled ? 1 : 0
  max_node_count           = var.autoscaling_enabled ? var.node_count * 2 : 0
  scale_down_cooldown_time = var.autoscaling_enabled ? 15 : 0
  priority                 = 1

  root_volume {
    size       = 50
    volumetype = "SSD"
  }

  data_volumes {
    size       = 100
    volumetype = "SSD"
  }

  user_tags = var.tags
}

output "node_pool_id" {
  value = opentelekomcloud_cce_node_pool_v3.this.id
}
