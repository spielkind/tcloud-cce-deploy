# =============================================================================
# Node pools — one opentelekomcloud_cce_node_pool_v3 per entry in var.node_pools
#
# Pool-level settings override the module-wide defaults (node_os, node_runtime,
# volume types). Pools with gpu = true get NVIDIA defaults for labels/taints
# unless they set their own, and enable the CCE AI Suite (NVIDIA GPU) addon.
# Any pool with autoscaling = true enables the cluster autoscaler addon.
# =============================================================================
locals {
  gpu_default_labels = { accelerator = "nvidia" }
  gpu_default_taints = [{ key = "nvidia.com/gpu", value = "present", effect = "NoSchedule" }]

  node_pools = {
    for key, p in var.node_pools : key => merge(p, {
      min_count = p.autoscaling ? coalesce(p.min_count, p.gpu ? 0 : 1) : 0
      count     = coalesce(p.count, p.autoscaling ? coalesce(p.min_count, p.gpu ? 0 : 1) : 1)
      max_count = p.autoscaling ? coalesce(
        p.max_count,
        max(2 * coalesce(p.count, p.autoscaling ? coalesce(p.min_count, p.gpu ? 0 : 1) : 1), 1)
      ) : 0
      priority = coalesce(p.priority, p.gpu ? 0 : 1)
      labels   = p.labels != null ? p.labels : (p.gpu ? local.gpu_default_labels : {})
      taints   = p.taints != null ? p.taints : (p.gpu ? local.gpu_default_taints : [])
    })
  }

  gpu_pools       = { for key, p in local.node_pools : key => p if p.gpu }
  gpu_enabled     = length(local.gpu_pools) > 0
  any_autoscaling = anytrue([for p in local.node_pools : p.autoscaling])
}

resource "opentelekomcloud_cce_node_pool_v3" "this" {
  for_each = local.node_pools

  cluster_id         = opentelekomcloud_cce_cluster_v3.this.id
  name               = "${var.name_prefix}-${each.key}"
  flavor             = each.value.flavor
  os                 = coalesce(each.value.os, var.node_os)
  runtime            = coalesce(each.value.runtime, var.node_runtime)
  initial_node_count = each.value.count
  key_pair           = opentelekomcloud_compute_keypair_v2.this.name
  subnet_id          = var.subnet_id
  availability_zone  = each.value.az

  scale_enable             = each.value.autoscaling
  min_node_count           = each.value.min_count
  max_node_count           = each.value.max_count
  scale_down_cooldown_time = each.value.autoscaling ? each.value.scale_down_cooldown : 0
  priority                 = each.value.priority
  k8s_tags                 = each.value.labels

  dynamic "taints" {
    for_each = each.value.taints
    content {
      key    = taints.value.key
      value  = taints.value.value
      effect = taints.value.effect
    }
  }

  root_volume {
    size       = each.value.root_volume_size
    volumetype = coalesce(each.value.root_volume_type, var.node_root_volume_type)
    kms_id     = local.node_volume_kms_id
  }

  data_volumes {
    size       = each.value.data_volume_size
    volumetype = coalesce(each.value.data_volume_type, var.node_data_volume_type)
    kms_id     = local.node_volume_kms_id
  }

  user_tags = var.tags

  lifecycle {
    ignore_changes = [initial_node_count]

    precondition {
      condition     = !each.value.autoscaling || (each.value.min_count <= each.value.count && each.value.count <= each.value.max_count)
      error_message = "Node pool ${each.key}: autoscaling requires min_count <= count <= max_count."
    }
  }

  depends_on = [opentelekomcloud_identity_agency_v3.evs_kms]
}
