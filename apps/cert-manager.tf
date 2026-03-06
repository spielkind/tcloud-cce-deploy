# =============================================================================
# cert-manager + ClusterIssuer (Let's Encrypt HTTP-01)
# =============================================================================
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "helm_release" "cluster_issuer" {
  name      = "cluster-issuer"
  chart     = "${path.module}/charts/cluster-issuer"
  namespace = "cert-manager"

  set {
    name  = "email"
    value = "admin@${local.zone_name}"
  }

  depends_on = [helm_release.cert_manager]
}
