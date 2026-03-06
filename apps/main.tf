terraform {
  required_version = ">= 1.5.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

locals {
  infra     = data.terraform_remote_state.infra.outputs
  api_host  = try(local.infra.cce_api_endpoint_public, local.infra.cce_api_endpoint)
  zone_name = trimsuffix(lookup(local.infra, "dns_zone_name", "otc.nodefall.de."), ".")
}

provider "helm" {
  kubernetes {
    host                   = local.api_host
    cluster_ca_certificate = base64decode(local.infra.cluster_ca_cert)
    client_certificate     = base64decode(local.infra.client_cert)
    client_key             = base64decode(local.infra.client_key)
  }
}

provider "kubernetes" {
  host                   = local.api_host
  cluster_ca_certificate = base64decode(local.infra.cluster_ca_cert)
  client_certificate     = base64decode(local.infra.client_cert)
  client_key             = base64decode(local.infra.client_key)
}
