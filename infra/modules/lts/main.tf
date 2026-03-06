terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "cluster_id" { type = string }
variable "create_lts_streams" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "opentelekomcloud_lts_group_v2" "k8s" {
  count       = var.create_lts_streams ? 1 : 0
  group_name  = "k8s-log-${var.cluster_id}"
  ttl_in_days = 7
  tags        = var.tags
}

locals {
  group_id = var.create_lts_streams ? opentelekomcloud_lts_group_v2.k8s[0].id : ""
}

resource "opentelekomcloud_lts_stream_v2" "stdout" {
  count       = var.create_lts_streams ? 1 : 0
  group_id    = local.group_id
  stream_name = "stdout-${var.cluster_id}"
}

resource "opentelekomcloud_lts_stream_v2" "containerfile" {
  count       = var.create_lts_streams ? 1 : 0
  group_id    = local.group_id
  stream_name = "containerfile-${var.cluster_id}"
}

resource "opentelekomcloud_lts_stream_v2" "hostfile" {
  count       = var.create_lts_streams ? 1 : 0
  group_id    = local.group_id
  stream_name = "hostfile-${var.cluster_id}"
}

resource "opentelekomcloud_lts_stream_v2" "event" {
  count       = var.create_lts_streams ? 1 : 0
  group_id    = local.group_id
  stream_name = "event-${var.cluster_id}"
}

output "log_group_id" {
  value = local.group_id
}

output "stdout_stream_id" {
  value = var.create_lts_streams ? opentelekomcloud_lts_stream_v2.stdout[0].id : ""
}

output "event_stream_id" {
  value = var.create_lts_streams ? opentelekomcloud_lts_stream_v2.event[0].id : ""
}
