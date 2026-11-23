# =============================================================================
# GPU Demo (AI playground on the GPU node pool, optional GPU slicing showcase)
# =============================================================================
locals {
  gpu_demo_enabled = var.create_gpu_demo && try(local.infra.gpu_node_pool_enabled, false)
  gpu_xgpu_infra   = try(local.infra.gpu_xgpu_enabled, false)
  gpu_slicing_on   = local.gpu_demo_enabled && coalesce(var.gpu_slicing.enabled, local.gpu_xgpu_infra)
}

resource "helm_release" "gpu_demo" {
  count     = local.gpu_demo_enabled ? 1 : 0
  name      = "gpu-demo"
  chart     = "${path.module}/charts/gpu-demo"
  namespace = "default"

  values = [yamlencode({
    image    = "${local.image_registry}/gpu-demo:${var.gpu_demo_image_tag}"
    hostname = "${var.gpu_demo_hostname}.${local.zone_name}"
    replicas = var.gpu_demo_replicas
    models   = var.gpu_demo_models
    openbao  = { enabled = var.gpu_demo_openbao && local.openbao_enabled }
    slicing = {
      enabled    = local.gpu_slicing_on
      playground = { memGib = var.gpu_slicing.playground.mem_gib, corePercent = var.gpu_slicing.playground.core_percent }
      workers    = [for w in var.gpu_slicing.workers : { name = w.name, memGib = w.mem_gib, corePercent = w.core_percent }]
    }
    # Labels/taints of the GPU node pool come from infra (node_pools).
    nodeSelector = try(local.infra.gpu_node_selector, { accelerator = "nvidia" })
    tolerations = try(local.infra.gpu_node_tolerations, [
      { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }
    ])
  })]

  # The GPU node is created on demand (autoscaler) and the model is downloaded on first start.
  wait = false

  lifecycle {
    precondition {
      condition     = !local.gpu_slicing_on || local.gpu_xgpu_infra
      error_message = "gpu_slicing.enabled = true needs gpu_xgpu = true in infra (xGPU + Volcano)."
    }
  }

  depends_on = [helm_release.cluster_issuer]
}
