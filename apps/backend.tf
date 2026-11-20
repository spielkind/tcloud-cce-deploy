terraform {
  backend "s3" {
    bucket                      = "test-tfstate-08a48bb9"
    key                         = "cce/apps.tfstate"
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
    bucket                      = "test-tfstate-08a48bb9"
    key                         = "cce/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
    encrypt                     = true
    kms_key_id                  = "arn:aws:kms:eu-de:a88b41fbfc8745dbb84b3778b9c3ded5:key/c9db39a3-b1ac-4928-98a9-a279d8c72fe9"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
