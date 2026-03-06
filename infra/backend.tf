terraform {
  backend "s3" {
    bucket                      = "mic-tfstate-25feabdc"
    key                         = "cce/terraform.tfstate"
    endpoint                    = "https://obs.eu-de.otc.t-systems.com"
    region                      = "eu-de"
    encrypt                     = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
