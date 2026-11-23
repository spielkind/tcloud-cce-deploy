resource "opentelekomcloud_lts_group_v2" "k8s" {
  count       = var.create_lts ? 1 : 0
  group_name  = "k8s-log-${opentelekomcloud_cce_cluster_v3.this.id}"
  ttl_in_days = var.lts_ttl_days
  tags        = var.tags
}

locals {
  group_id = var.create_lts ? opentelekomcloud_lts_group_v2.k8s[0].id : ""
}

# Streams inherit the group retention (lts_ttl_days).
# stdout/event: filled by the log-agent default LogConfigs.
# hostfile: filled by the host_file LogConfigs in workloads/logging.tf.
resource "opentelekomcloud_lts_stream_v2" "stdout" {
  count       = var.create_lts ? 1 : 0
  group_id    = local.group_id
  stream_name = "stdout-${opentelekomcloud_cce_cluster_v3.this.id}"
  tags        = var.tags
}

# Expected by the CCE console "Container logs" tab; filled once a container_file LogConfig exists.
resource "opentelekomcloud_lts_stream_v2" "containerfile" {
  count       = var.create_lts ? 1 : 0
  group_id    = local.group_id
  stream_name = "containerfile-${opentelekomcloud_cce_cluster_v3.this.id}"
  tags        = var.tags
}

resource "opentelekomcloud_lts_stream_v2" "hostfile" {
  count       = var.create_lts ? 1 : 0
  group_id    = local.group_id
  stream_name = "hostfile-${opentelekomcloud_cce_cluster_v3.this.id}"
  tags        = var.tags
}

resource "opentelekomcloud_lts_stream_v2" "event" {
  count       = var.create_lts ? 1 : 0
  group_id    = local.group_id
  stream_name = "event-${opentelekomcloud_cce_cluster_v3.this.id}"
  tags        = var.tags
}
