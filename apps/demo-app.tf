# =============================================================================
# Demo App (Helm)
# =============================================================================
resource "helm_release" "demo_app" {
  count     = var.create_openbao && var.create_demo_app ? 1 : 0
  name      = "demo-app"
  chart     = "${path.module}/charts/demo-app"
  namespace = "default"

  values = [yamlencode({
    image    = "${local.infra.swr_endpoint}/${local.infra.swr_organization}/demo-app:${var.demo_app_image_tag}"
    hostname = "${var.demo_app_hostname}.${local.zone_name}"
    baoAddr  = "http://openbao.${kubernetes_namespace_v1.openbao[0].metadata[0].name}.svc:8200"
  })]

  # Pods need OpenBao initialization and Kubernetes auth, which are set up after deployment.
  wait = false

  depends_on = [helm_release.cluster_issuer, helm_release.openbao]
}
