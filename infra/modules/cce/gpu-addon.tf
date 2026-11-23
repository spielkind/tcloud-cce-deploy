resource "opentelekomcloud_cce_addon_v3" "gpu" {
  count = local.gpu_enabled ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "gpu-beta"
  template_version = local.addon_version["gpu-beta"]

  values {
    basic_json = jsonencode({
      device_version = local.addon_version["gpu-beta"]
      driver_version = local.addon_version["gpu-beta"]
      obs_url        = try(coalesce(local.addon_template["gpu-beta"].obs_url), "obs.${local.service_domain}")
      region         = var.region
      swr_addr       = local.addon_swr_addr["gpu-beta"]
      swr_user       = local.addon_swr_user["gpu-beta"]
    })
    custom_json = jsonencode({
      is_driver_from_nvidia            = true
      nvidia_driver_download_url       = var.nvidia_driver_url
      enable_metrics_monitoring        = true
      enable_health_monitoring         = true
      compatible_with_legacy_api       = false
      component_schedulername          = "default-scheduler"
      enable_pod_eviction_on_gpu_error = false
    })
    flavor_json = jsonencode({
      description = "custom-resources"
      name        = "custom-resources"
      size        = "custom"
      replicas    = 1
      resources = [
        { name = "nvidia-gpu-device-plugin", requestsCpu = "50m", requestsMem = "100Mi", limitsCpu = "2000m", limitsMem = "900Mi" },
        { name = "nvidia-operator", replicas = 1, requestsCpu = "100m", requestsMem = "128Mi" },
      ]
    })
  }

  lifecycle {
    precondition {
      condition     = local.addon_version["gpu-beta"] != null
      error_message = "No gpu-beta addon template found for ${var.cluster_version}."
    }
  }

  depends_on = [opentelekomcloud_cce_node_pool_v3.this]
}
