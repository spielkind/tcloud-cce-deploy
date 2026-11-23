# The bucket is created by bootstrap/ (it rewrites the name on a new bootstrap).
# The state key comes from envs/<env>.backend.tfvars; the bucket's default
# SSE-KMS encryption covers the state objects, so no KMS key ID is pinned here.
terraform {
  backend "s3" {
    bucket                      = "test-tfstate-610e8313"
    key                         = "dev/workloads/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
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
    bucket                      = "test-tfstate-610e8313"
    key                         = "${var.environment}/infra/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
