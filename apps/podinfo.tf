# =============================================================================
# podinfo (hello world with TLS)
# =============================================================================
resource "helm_release" "podinfo" {
  count            = var.create_podinfo ? 1 : 0
  name             = "podinfo"
  repository       = "https://stefanprodan.github.io/podinfo"
  chart            = "podinfo"
  namespace        = "default"
  create_namespace = false

  set {
    name  = "ingress.enabled"
    value = "true"
  }

  set {
    name  = "ingress.className"
    value = "nginx"
  }

  set {
    name  = "ingress.annotations.cert-manager\\.io/cluster-issuer"
    value = "letsencrypt-prod"
  }

  set {
    name  = "ingress.hosts[0].host"
    value = "hello.${local.zone_name}"
  }

  set {
    name  = "ingress.hosts[0].paths[0].path"
    value = "/"
  }

  set {
    name  = "ingress.hosts[0].paths[0].pathType"
    value = "Prefix"
  }

  set {
    name  = "ingress.tls[0].secretName"
    value = "hello-tls"
  }

  set {
    name  = "ingress.tls[0].hosts[0]"
    value = "hello.${local.zone_name}"
  }

  depends_on = [helm_release.cluster_issuer]
}
