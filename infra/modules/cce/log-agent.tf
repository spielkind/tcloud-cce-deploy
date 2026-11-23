locals {
  lts_endpoints = {
    aomEndpoint       = "https://aom.${local.service_domain}"
    ltsAccessEndpoint = "https://lts-access.${local.service_domain}:8102"
    ltsEndpoint       = "https://lts.${local.service_domain}"
  }
}

resource "opentelekomcloud_cce_addon_v3" "log_agent" {
  count = var.create_lts ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "log-agent"
  template_version = local.addon_version["log-agent"]

  values {
    basic_json = jsonencode(merge(local.lts_endpoints, {
      swr_addr = local.addon_swr_addr["log-agent"]
      swr_user = local.addon_swr_user["log-agent"]
      region   = var.region
    }))
    custom_json = jsonencode(merge(local.lts_endpoints, {
      createDefaultStdout     = true
      createDefaultEvent      = true
      createDefaultEventToAOM = true
      enableEventReport       = true
      enableLogReport         = true
      enableLogOperatorHA     = true
      clusterName             = opentelekomcloud_cce_cluster_v3.this.name
      paasakskEnable          = true
      ltsGroupID              = local.group_id
      ltsStdoutStreamID       = opentelekomcloud_lts_stream_v2.stdout[0].id
      ltsEventStreamID        = opentelekomcloud_lts_stream_v2.event[0].id
    }))
    flavor_json = jsonencode({})
  }

  lifecycle {
    precondition {
      condition     = local.addon_version["log-agent"] != null
      error_message = "No log-agent addon template found for ${var.cluster_version}."
    }
  }

  depends_on = [opentelekomcloud_cce_node_pool_v3.this, opentelekomcloud_lts_stream_v2.stdout]
}
