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

# Bootstrap state is intentionally kept local (bootstrap/terraform.tfstate,
# gitignored): the bucket that would hold it is created here. Keep a backup of
# that file; losing it only means re-importing the bucket and key.

resource "random_id" "id" {
  byte_length = 4
}

resource "opentelekomcloud_kms_key_v1" "state" {
  key_alias       = "${var.name_prefix}-tfstate-${random_id.id.hex}-key"
  key_description = "${var.name_prefix}-tfstate-${random_id.id.hex} encryption key"
  pending_days    = 7
  is_enabled      = true

  rotation_enabled  = true
  rotation_interval = 365

  tags = var.tags
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

locals {
  environments = ["dev", "prod"]

  # State object keys: <environment>/<stack>/terraform.tfstate
  state_keys = {
    for env in local.environments : env => {
      infra     = "${env}/infra/terraform.tfstate"
      workloads = "${env}/workloads/terraform.tfstate"
    }
  }

  obs_endpoint = "https://obs.${var.region}.otc.t-systems.com"
}

# infra/backend.tf; the key defaults to dev and is overridden per environment
# with -backend-config=envs/<env>.backend.tfvars.
output "backend_config" {
  value = <<-EOT
    # The key is overridden per environment with
    #   tofu init -backend-config=envs/<env>.backend.tfvars
    # (dev/infra/terraform.tfstate or prod/infra/terraform.tfstate).
    # No `encrypt = true`: it would send an AES256 header that overrides the bucket's
    # default SSE-KMS encryption.
    terraform {
      backend "s3" {
        bucket                      = "${opentelekomcloud_obs_bucket.state.bucket}"
        key                         = "${local.state_keys["dev"].infra}"
        endpoint                    = "${local.obs_endpoint}"
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

# workloads/backend.tf; the remote state key follows var.environment.
output "workloads_backend_config" {
  value = <<-EOT
    # The bucket is created by bootstrap/ (it rewrites the name on a new bootstrap).
    # The state key comes from envs/<env>.backend.tfvars; the bucket's default
    # SSE-KMS encryption covers the state objects, so no KMS key ID is pinned here.
    terraform {
      backend "s3" {
        bucket                      = "${opentelekomcloud_obs_bucket.state.bucket}"
        key                         = "${local.state_keys["dev"].workloads}"
        endpoint                    = "${local.obs_endpoint}"
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
        key                         = "$${var.environment}/infra/terraform.tfstate"
        endpoint                    = "${local.obs_endpoint}"
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

# Per-environment -backend-config files:
#   envs/<env>.backend.tfvars for infra and workloads.
output "backend_tfvars" {
  value = {
    for env, keys in local.state_keys : env => {
      infra     = "key = \"${keys.infra}\"\n"
      workloads = "key = \"${keys.workloads}\"\n"
    }
  }
}

output "state_keys" {
  value = local.state_keys
}

output "bucket_name" {
  value = opentelekomcloud_obs_bucket.state.bucket
}

output "kms_key_id" {
  value = opentelekomcloud_kms_key_v1.state.id
}
