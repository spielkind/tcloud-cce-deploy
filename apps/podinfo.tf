# =============================================================================
# podinfo (hello world with TLS)
# =============================================================================
resource "helm_release" "podinfo" {
  count      = var.create_podinfo ? 1 : 0
  name       = "podinfo"
  repository = "https://stefanprodan.github.io/podinfo"
  chart      = "podinfo"
  version    = var.podinfo_version
  namespace  = "default"

  values = [yamlencode({
    ingress = {
      enabled   = true
      className = "nginx"
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      }
      hosts = [{
        host  = "hello.${local.zone_name}"
        paths = [{ path = "/", pathType = "Prefix" }]
      }]
      tls = [{
        secretName = "hello-tls"
        hosts      = ["hello.${local.zone_name}"]
      }]
    }
  })]

  depends_on = [helm_release.cluster_issuer]
}
