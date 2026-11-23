# =============================================================================
# Demo App (Helm)
# =============================================================================
resource "helm_release" "demo_app" {
  count     = var.create_demo_app && local.openbao_enabled ? 1 : 0
  name      = "demo-app"
  chart     = "${path.module}/charts/demo-app"
  namespace = "default"

  values = [yamlencode({
    image      = "${local.image_registry}/demo-app:${var.demo_app_image_tag}"
    hostname   = "${var.demo_app_hostname}.${local.zone_name}"
    baoAddr    = local.openbao_in_cluster_url
    baoCaCert  = local.openbao_vm_enabled ? local.openbao_vm_ca_cert : ""
    accessMode = var.demo_app_access_mode
  })]

  # Pods need OpenBao initialization and Kubernetes auth, which are set up after deployment.
  wait = false

  depends_on = [helm_release.cluster_issuer, helm_release.openbao, helm_release.openbao_injector]
}
