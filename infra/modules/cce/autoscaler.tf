resource "opentelekomcloud_cce_addon_v3" "autoscaler" {
  count = local.autoscaler_enabled ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "autoscaler"
  template_version = local.addon_version["autoscaler"]

  values {
    basic_json = jsonencode({
      cceEndpoint = "https://cce.${local.service_domain}"
      ecsEndpoint = "https://ecs.${local.service_domain}"
      region      = var.region
      swr_addr    = local.addon_swr_addr["autoscaler"]
      swr_user    = local.addon_swr_user["autoscaler"]
    })
    custom_json = jsonencode({
      cluster_id                     = opentelekomcloud_cce_cluster_v3.this.id
      tenant_id                      = var.project_id
      coresTotal                     = 32000
      memoryTotal                    = 128000
      maxNodesTotal                  = 1000
      expander                       = "priority,least-waste"
      logLevel                       = 4
      maxEmptyBulkDeleteFlag         = 10
      maxNodeProvisionTime           = 15
      scaleDownEnabled               = true
      scaleDownDelayAfterAdd         = 10
      scaleDownDelayAfterDelete      = 10
      scaleDownDelayAfterFailure     = 3
      scaleDownUnneededTime          = 10
      scaleDownUtilizationThreshold  = 0.5
      scaleUpCpuUtilizationThreshold = 1
      scaleUpMemUtilizationThreshold = 1
      scaleUpUnscheduledPodEnabled   = true
      scaleUpUtilizationEnabled      = true
    })
    flavor_json = jsonencode({
      description = "Has only one instance"
      name        = "Single"
      replicas    = 1
      resources = [{
        name        = "autoscaler"
        limitsCpu   = "1000m"
        limitsMem   = "1000Mi"
        requestsCpu = "500m"
        requestsMem = "500Mi"
      }]
    })
  }

  lifecycle {
    precondition {
      condition     = local.addon_version["autoscaler"] != null
      error_message = "No autoscaler addon template found for ${var.cluster_version}."
    }
  }

  depends_on = [opentelekomcloud_cce_node_pool_v3.this]
}
