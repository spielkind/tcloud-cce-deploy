terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "cluster_id" { type = string }
variable "create_log_agent" {
  type    = bool
  default = false
}
variable "log_agent_version" {
  type    = string
  default = "1.7.6"
}

variable "cluster_name" {
  type    = string
  default = ""
}

variable "lts_group_id" {
  type    = string
  default = ""
}
variable "lts_stdout_stream_id" {
  type    = string
  default = ""
}
variable "lts_event_stream_id" {
  type    = string
  default = ""
}

resource "opentelekomcloud_cce_addon_v3" "log_agent" {
  count = var.create_log_agent ? 1 : 0

  cluster_id       = var.cluster_id
  template_name    = "log-agent"
  template_version = var.log_agent_version

  values {
    basic_json = jsonencode({
      swr_addr            = "swr.eu-de.otc.t-systems.com"
      aomEndpoint         = "https://aom.eu-de.otc.t-systems.com"
      ltsAccessEndpoint   = "https://lts-access.eu-de.otc.t-systems.com:8102"
      ltsEndpoint         = "https://lts.eu-de.otc.t-systems.com"
      swr_user = "cce-addons"
      region   = "eu-de"
    })
    custom_json = jsonencode({
      createDefaultStdout              = true
      createDefaultEvent               = true
      createDefaultEventToAOM          = true
      enableEventReport                = true
      enableLogReport                  = true
      enableLogOperatorHA              = true
      clusterName                      = var.cluster_name
      paasakskEnable                   = true
      ltsGroupID                       = var.lts_group_id
      ltsStdoutStreamID                = var.lts_stdout_stream_id
      ltsEventStreamID                 = var.lts_event_stream_id
      aomEndpoint                      = "https://aom.eu-de.otc.t-systems.com"
      ltsAccessEndpoint                = "https://lts-access.eu-de.otc.t-systems.com:8102"
      ltsEndpoint                      = "https://lts.eu-de.otc.t-systems.com"
    })
    flavor_json = jsonencode({})
  }
}
