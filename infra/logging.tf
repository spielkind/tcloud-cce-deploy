# =============================================================================
# VPC flow logs (optional) -> own stream in the cluster LTS group
# =============================================================================
resource "opentelekomcloud_lts_stream_v2" "vpc_flow_log" {
  count       = var.vpc_flow_log_enabled ? 1 : 0
  group_id    = module.cce.lts_group_id
  stream_name = "vpc-flow-${var.name_prefix}"
  tags        = local.tags
}

resource "opentelekomcloud_vpc_flow_log_v1" "cluster" {
  count         = var.vpc_flow_log_enabled ? 1 : 0
  name          = "${var.name_prefix}-vpc-flow"
  description   = "Flow log of the cluster VPC"
  resource_type = "vpc"
  resource_id   = module.vpc.vpc_id
  traffic_type  = var.vpc_flow_log_traffic
  log_group_id  = module.cce.lts_group_id
  log_topic_id  = opentelekomcloud_lts_stream_v2.vpc_flow_log[0].id
  enabled       = true

  lifecycle {
    precondition {
      condition     = var.create_lts
      error_message = "vpc_flow_log_enabled requires create_lts = true (the flow log uses the cluster LTS group)."
    }
  }
}
