# =============================================================================
# GPU Demo (text-to-image on the GPU node pool)
# =============================================================================
locals {
  gpu_demo_enabled = var.create_gpu_demo && try(local.infra.gpu_node_pool_enabled, false)
}

resource "helm_release" "gpu_demo" {
  count     = local.gpu_demo_enabled ? 1 : 0
  name      = "gpu-demo"
  chart     = "${path.module}/charts/gpu-demo"
  namespace = "default"

  values = [yamlencode({
    image    = "${local.infra.swr_endpoint}/${local.infra.swr_organization}/gpu-demo:${var.gpu_demo_image_tag}"
    hostname = "${var.gpu_demo_hostname}.${local.zone_name}"
    replicas = var.gpu_demo_replicas
    modelId  = var.gpu_demo_model
  })]

  # The GPU node is created on demand (autoscaler) and the model is downloaded on first start.
  wait = false

  depends_on = [helm_release.cluster_issuer]
}
