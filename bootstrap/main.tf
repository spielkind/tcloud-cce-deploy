terraform {
  required_version = ">= 1.10.0"
  required_providers {
    opentelekomcloud = {
      source  = "opentelekomcloud/opentelekomcloud"
      version = "~> 1.37"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

variable "name_prefix" {
  default = "test"
  type    = string
}

variable "region" {
  type    = string
  default = "eu-de"
}

variable "otc_access_key" {
  type      = string
  sensitive = true
}

variable "otc_secret_key" {
  type      = string
  sensitive = true
}


variable "otc_domain_name" {
  type = string
}

variable "tags" {
  description = "Default tags for all resources"
  type        = map(string)
  default = {
    managed_by = "terraform"
    project    = "test"
  }
}

provider "opentelekomcloud" {
  access_key  = var.otc_access_key
  secret_key  = var.otc_secret_key
  domain_name = var.otc_domain_name
  # OBS bucket encryption only accepts KMS keys from the region's base project.
  tenant_name = var.region
  auth_url    = "https://iam.${var.region}.otc.t-systems.com/v3"
}

resource "random_id" "id" {
  byte_length = 4
}

resource "opentelekomcloud_kms_key_v1" "state" {
  key_alias       = "${var.name_prefix}-tfstate-${random_id.id.hex}-key"
  key_description = "${var.name_prefix}-tfstate-${random_id.id.hex} encryption key"
  pending_days    = 7
  is_enabled      = true
  tags            = var.tags
}

resource "opentelekomcloud_obs_bucket" "state" {
  bucket     = "${var.name_prefix}-tfstate-${random_id.id.hex}"
  acl        = "private"
  versioning = true
  tags       = var.tags

  server_side_encryption {
    algorithm  = "kms"
    kms_key_id = opentelekomcloud_kms_key_v1.state.id
  }

  lifecycle_rule {
    name    = "cleanup-old-versions"
    enabled = true
    noncurrent_version_expiration {
      days = 90
    }
  }
}

output "backend_config" {
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket                      = "${opentelekomcloud_obs_bucket.state.bucket}"
        key                         = "cce/terraform.tfstate"
        endpoint                    = "https://obs.${var.region}.otc.t-systems.com"
        region                      = "${var.region}"
        skip_credentials_validation = true
        skip_region_validation      = true
        skip_metadata_api_check     = true
        skip_requesting_account_id  = true
        skip_s3_checksum            = true
      }
    }
  EOT
}

output "apps_backend_config" {
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket                      = "${opentelekomcloud_obs_bucket.state.bucket}"
        key                         = "cce/apps.tfstate"
        endpoint                    = "https://obs.${var.region}.otc.t-systems.com"
        region                      = "${var.region}"
        skip_credentials_validation = true
        skip_region_validation      = true
        skip_metadata_api_check     = true
        skip_requesting_account_id  = true
        skip_s3_checksum            = true
      }
    }

    data "terraform_remote_state" "infra" {
      backend = "s3"
      config = {
        bucket                      = "${opentelekomcloud_obs_bucket.state.bucket}"
        key                         = "cce/terraform.tfstate"
        endpoint                    = "https://obs.${var.region}.otc.t-systems.com"
        region                      = "${var.region}"
        encrypt                     = true
        kms_key_id                  = "arn:aws:kms:${var.region}:${opentelekomcloud_kms_key_v1.state.domain_id}:key/${opentelekomcloud_kms_key_v1.state.id}"
        skip_credentials_validation = true
        skip_region_validation      = true
        skip_metadata_api_check     = true
        skip_requesting_account_id  = true
        skip_s3_checksum            = true
      }
    }
  EOT
}

output "bucket_name" {
  value = opentelekomcloud_obs_bucket.state.bucket
}

output "kms_key_id" {
  value = opentelekomcloud_kms_key_v1.state.id
}
