# The key is overridden per environment with
#   tofu init -backend-config=envs/<env>.backend.tfvars
# (dev/infra/terraform.tfstate or prod/infra/terraform.tfstate).
# No `encrypt = true`: it would send an AES256 header that overrides the bucket's
# default SSE-KMS encryption.
terraform {
  backend "s3" {
    bucket                      = "test-tfstate-610e8313"
    key                         = "dev/infra/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
