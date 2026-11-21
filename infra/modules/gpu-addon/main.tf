terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

# =============================================================================
# CCE AI Suite (NVIDIA GPU) — device plugin + NVIDIA driver installer
# =============================================================================

variable "create_gpu_addon" {
  type    = bool
  default = false
}
variable "cluster_id" { type = string }
variable "addon_version" {
  type    = string
  default = "2.15.6"
}
variable "driver_url" {
  description = "NVIDIA Tesla driver .run download URL (nodes need internet access via NAT)"
  type        = string
}
variable "region" {
  type    = string
  default = "eu-de"
}

resource "opentelekomcloud_cce_addon_v3" "gpu" {
  count = var.create_gpu_addon ? 1 : 0

  cluster_id       = var.cluster_id
  template_name    = "gpu-beta"
  template_version = var.addon_version

  values {
    basic_json = jsonencode({
      device_version = var.addon_version
      driver_version = var.addon_version
      obs_url        = "obs.${var.region}.otc.t-systems.com"
      region         = var.region
      swr_addr       = "swr.${var.region}.otc.t-systems.com"
      swr_user       = "cce-addons"
    })
    custom_json = jsonencode({
      is_driver_from_nvidia            = true
      nvidia_driver_download_url       = var.driver_url
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
}

output "addon_id" {
  value = var.create_gpu_addon ? opentelekomcloud_cce_addon_v3.gpu[0].id : null
}
