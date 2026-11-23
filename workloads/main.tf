terraform {
  required_version = ">= 1.10.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }
}

locals {
  infra            = data.terraform_remote_state.infra.outputs
  api_host         = try(local.infra.cce_api_endpoint_public, local.infra.cce_api_endpoint)
  zone_name        = trimsuffix(local.infra.dns_zone_name, ".")
  otc_project_name = local.infra.otc_project_name
  region           = try(local.infra.region, "eu-de")
  # OpenBao placement is decided by infra (openbao_mode = disabled | cce | vm).
  selected_bao_mode = try(local.infra.openbao_mode, "disabled")
  image_registry    = "${local.infra.swr_endpoint}/${local.infra.swr_organization}"
}

provider "helm" {
  kubernetes = {
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
