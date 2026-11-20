terraform {
  backend "s3" {
    bucket                      = "test-tfstate-08a48bb9"
    key                         = "cce/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
