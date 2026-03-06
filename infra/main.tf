terraform {
  required_version = ">= 1.5.0"

  required_providers {
    opentelekomcloud = {
      source  = "opentelekomcloud/opentelekomcloud"
      version = "~> 1.36"
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

