# Metrics Server (resource metrics API for HPA/VPA and kubectl top)
resource "opentelekomcloud_cce_addon_v3" "metrics" {
  count = var.create_metrics_server ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "metrics-server"
  template_version = local.addon_version["metrics-server"]

  values {
    basic_json = jsonencode({
      swr_addr = local.addon_swr_addr["metrics-server"]
      swr_user = local.addon_swr_user["metrics-server"]
    })
    custom_json = jsonencode({})
    flavor_json = jsonencode({})
  }

  lifecycle {
    precondition {
      condition     = local.addon_version["metrics-server"] != null
      error_message = "No metrics-server addon template found for ${var.cluster_version}."
    }
  }

  depends_on = [opentelekomcloud_cce_node_pool_v3.this]
}
