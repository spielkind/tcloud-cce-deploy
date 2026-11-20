terraform {
  required_version = ">= 1.10.0"

  required_providers {
    opentelekomcloud = {
      source  = "opentelekomcloud/opentelekomcloud"
      version = "~> 1.37"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "opentelekomcloud" {
  access_key  = var.otc_access_key
  secret_key  = var.otc_secret_key
  domain_name = var.otc_domain_name
  tenant_name = var.otc_project_name
  auth_url    = "https://iam.${var.region}.otc.t-systems.com/v3"
  region      = var.region
}

