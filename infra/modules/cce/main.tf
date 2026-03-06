terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

variable "name_prefix" { type = string }
variable "cluster_flavor" { type = string }
variable "cluster_version" {
  type    = string
  default = "v1.32"
}
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" {
  type    = string
  default = ""
}
variable "high_availability" {
  type    = bool
  default = false
}
variable "cluster_type" {
  type    = string
  default = "VirtualMachine"
}
variable "kube_proxy_mode" {
  type    = string
  default = "iptables"
}
variable "container_network_type" {
  type    = string
  default = "overlay_l2"
}
variable "eni_subnet_id" {
  description = "Subnet ID for ENI (required for Yangtse/eni mode)"
  type        = string
  default     = ""
}
variable "eni_subnet_cidr" {
  description = "Subnet CIDR for ENI (required for Yangtse/eni mode)"
  type        = string
  default     = ""
}


# --- EIP for kubectl access ---
resource "opentelekomcloud_vpc_eip_v1" "cce_api" {
  count = var.bind_eip ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-cce-api-bw"
    size       = 10
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_cce_cluster_v3" "this" {
  name                   = "${var.name_prefix}-cluster"
  description            = "Managed CCE Cluster"
  cluster_type           = var.cluster_type
  flavor_id              = var.cluster_flavor
  cluster_version        = var.cluster_version
  vpc_id                 = var.vpc_id
  subnet_id              = var.subnet_id
  container_network_type = var.container_network_type
  authentication_mode    = "rbac"
  kube_proxy_mode        = var.kube_proxy_mode
  security_group_id      = var.security_group_id != "" ? var.security_group_id : null
  delete_all_storage     = "true"
  delete_all_network     = "true"
  eip                    = var.bind_eip ? opentelekomcloud_vpc_eip_v1.cce_api[0].publicip[0].ip_address : null

  # ENI/Yangtse settings (only used when container_network_type = "eni")
  eni_subnet_id   = var.container_network_type == "eni" ? var.eni_subnet_id : null
  eni_subnet_cidr = var.container_network_type == "eni" ? var.eni_subnet_cidr : null



  dynamic "masters" {
    for_each = var.high_availability ? ["eu-de-01", "eu-de-02", "eu-de-03"] : []
    content {
      availability_zone = masters.value
    }
  }
}

output "cluster_id" {
  value = opentelekomcloud_cce_cluster_v3.this.id
}

output "cluster_name" {
  value = opentelekomcloud_cce_cluster_v3.this.name
}

output "cluster_api_endpoint" {
  value = opentelekomcloud_cce_cluster_v3.this.certificate_clusters[0].server
}

output "cluster_ca_cert" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_clusters[0].certificate_authority_data
  sensitive = true
}

output "client_cert" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_users[0].client_certificate_data
  sensitive = true
}

output "client_key" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_users[0].client_key_data
  sensitive = true
}



variable "bind_eip" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

output "cluster_api_public_ip" {
  value = var.bind_eip ? opentelekomcloud_vpc_eip_v1.cce_api[0].publicip[0].ip_address : null
}
