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

  values = [yamlencode({
    crds = { enabled = true }
  })]
}

resource "helm_release" "cluster_issuer" {
  name      = "cluster-issuer"
  chart     = "${path.module}/charts/cluster-issuer"
  namespace = "cert-manager"

  values = [yamlencode({
    email = "admin@${local.zone_name}"
  })]

  depends_on = [helm_release.cert_manager]
}
