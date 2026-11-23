# =============================================================================
# Volcano scheduler (GPU slicing)
# CCE xGPU splits one GPU into slices with hard VRAM and compute limits. Pods
# request volcano.sh/gpu-mem.128Mi and volcano.sh/gpu-core.percentage and set
# schedulerName: volcano; all other pods keep using the default scheduler.
# default_scheduler_conf is the template default plus binpack (fills one GPU
# before using the next); values not set here are taken from the template.
# =============================================================================
resource "opentelekomcloud_cce_addon_v3" "volcano" {
  count = local.xgpu_enabled ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "volcano"
  template_version = local.addon_version["volcano"]

  values {
    basic_json = jsonencode({
      platform = "linux-amd64"
      swr_addr = local.addon_swr_addr["volcano"]
      swr_user = local.addon_swr_user["volcano"]
    })
    custom_json = jsonencode({
      default_scheduler_conf = {
        actions = "allocate, backfill, preempt"
        tiers = [
          { plugins = [
            { name = "priority" },
            { name = "gang", enablePreemptable = false, enableReclaimable = false, enableJobStarving = false },
            { name = "conformance" },
            { name = "capacity", enableHierarchy = true },
          ] },
          { plugins = [
            { name = "drf", enablePreemptable = false, enableReclaimable = false },
            { name = "predicates" },
            { name = "nodeorder" },
            { name = "binpack" },
          ] },
          { plugins = [
            { name = "cce-gpu-topology-predicate" },
            { name = "cce-gpu-topology-priority" },
            { name = "xgpu" },
          ] },
          { plugins = [
            { name = "nodelocalvolume" },
            { name = "nodeemptydirvolume" },
            { name = "nodeCSIscheduling" },
            { name = "networkresource" },
          ] },
        ]
      }
    })
    # One replica per component is enough for the demo.
    flavor_json = jsonencode({
      description = "custom-resources"
      name        = "custom-resources"
      size        = "custom"
      replicas    = 1
      resources = [
        { name = "volcano-scheduler", replicas = 1, requestsCpu = "500m", requestsMem = "500Mi", limitsCpu = "2000m", limitsMem = "2000Mi" },
        { name = "volcano-controller", replicas = 1, requestsCpu = "500m", requestsMem = "500Mi", limitsCpu = "2000m", limitsMem = "2000Mi" },
        { name = "volcano-admission", replicas = 1, requestsCpu = "200m", requestsMem = "500Mi", limitsCpu = "500m", limitsMem = "500Mi" },
        { name = "volcano-agent", requestsCpu = "100m", requestsMem = "150Mi", limitsCpu = "200m", limitsMem = "200Mi" },
        { name = "resource-exporter", requestsCpu = "50m", requestsMem = "50Mi", limitsCpu = "100m", limitsMem = "100Mi" },
      ]
    })
  }

  lifecycle {
    precondition {
      condition     = local.addon_version["volcano"] != null
      error_message = "No volcano addon template found for ${var.cluster_version}."
    }
  }

  depends_on = [opentelekomcloud_cce_addon_v3.gpu]
}
