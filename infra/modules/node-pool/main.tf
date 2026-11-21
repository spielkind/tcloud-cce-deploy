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
variable "pool_name" {
  description = "Suffix of the node pool name (<name_prefix>-<pool_name>)"
  type        = string
  default     = "pool"
}
variable "min_node_count" {
  description = "Autoscaling minimum (default 1)"
  type        = number
  default     = null
}
variable "max_node_count" {
  description = "Autoscaling maximum (default 2 x node_count)"
  type        = number
  default     = null
}
variable "priority" {
  type    = number
  default = 1
}
variable "k8s_labels" {
  description = "Kubernetes labels for the nodes"
  type        = map(string)
  default     = {}
}
variable "taints" {
  description = "Kubernetes taints for the nodes"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}
variable "root_volume_size" {
  type    = number
  default = 50
}
variable "data_volume_size" {
  type    = number
  default = 100
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
  name       = "${var.name_prefix}-${var.pool_name}"
  flavor     = var.node_flavor
  os         = var.node_os

  initial_node_count = var.node_count
  key_pair           = var.key_pair
  subnet_id          = var.subnet_id
  availability_zone  = length(var.availability_zones) > 1 ? "random" : var.availability_zones[0]

  scale_enable             = var.autoscaling_enabled
  min_node_count           = var.autoscaling_enabled ? coalesce(var.min_node_count, 1) : 0
  max_node_count           = var.autoscaling_enabled ? coalesce(var.max_node_count, var.node_count * 2) : 0
  scale_down_cooldown_time = var.autoscaling_enabled ? 15 : 0
  priority                 = var.priority

  k8s_tags = var.k8s_labels

  dynamic "taints" {
    for_each = var.taints
    content {
      key    = taints.value.key
      value  = taints.value.value
      effect = taints.value.effect
    }
  }

  root_volume {
    size       = var.root_volume_size
    volumetype = "SSD"
  }

  data_volumes {
    size       = var.data_volume_size
    volumetype = "SSD"
  }

  user_tags = var.tags
}

output "node_pool_id" {
  value = opentelekomcloud_cce_node_pool_v3.this.id
}
