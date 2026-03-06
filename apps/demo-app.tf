# =============================================================================
# Demo App (Helm)
# =============================================================================
resource "helm_release" "demo_app" {
  count     = var.create_demo_app ? 1 : 0
  name      = "demo-app"
  chart     = "${path.module}/charts/demo-app"
  namespace = "default"

  set {
    name  = "image"
    value = "${data.terraform_remote_state.infra.outputs.swr_endpoint}/${data.terraform_remote_state.infra.outputs.swr_organization}/demo-app:latest"
  }

  set {
    name  = "hostname"
    value = "${var.demo_app_hostname}.${local.zone_name}"
  }

  timeout    = 120

depends_on = [helm_release.cluster_issuer, helm_release.vault]
}
