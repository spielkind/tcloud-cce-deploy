terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

# =============================================================================
# Cluster Autoscaler (CCE addon) — scales node pools with scale_enable = true
# =============================================================================

variable "create_autoscaler" {
  type    = bool
  default = false
}
variable "cluster_id" { type = string }
variable "project_id" { type = string }
variable "autoscaler_version" {
  type    = string
  default = "1.35.8"
}
variable "region" {
  type    = string
  default = "eu-de"
}

resource "opentelekomcloud_cce_addon_v3" "autoscaler" {
  count = var.create_autoscaler ? 1 : 0

  cluster_id       = var.cluster_id
  template_name    = "autoscaler"
  template_version = var.autoscaler_version

  values {
    basic_json = jsonencode({
      cceEndpoint = "https://cce.${var.region}.otc.t-systems.com"
      ecsEndpoint = "https://ecs.${var.region}.otc.t-systems.com"
      region      = var.region
      swr_addr    = "swr.${var.region}.otc.t-systems.com"
      swr_user    = "cce-addons"
    })
    custom_json = jsonencode({
      cluster_id                     = var.cluster_id
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
}

output "addon_id" {
  value = var.create_autoscaler ? opentelekomcloud_cce_addon_v3.autoscaler[0].id : null
}
