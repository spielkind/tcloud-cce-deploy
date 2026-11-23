locals {
  # eu-ch2 service endpoints live below the .sc sub-domain.
  service_domain = var.region == "eu-ch2" ? "eu-ch2.sc.otc.t-systems.com" : "${var.region}.otc.t-systems.com"
  is_turbo       = var.container_network_type == "eni"
}

# EIP for public kubectl access
resource "opentelekomcloud_vpc_eip_v1" "cce_api" {
  count = var.bind_eip ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-cce-api-bw"
    size       = var.api_eip_bandwidth
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_cce_cluster_v3" "this" {
  name                    = "${var.name_prefix}-cluster"
  description             = "Managed CCE Cluster"
  cluster_type            = var.cluster_type
  flavor_id               = var.cluster_flavor
  cluster_version         = var.cluster_version
  vpc_id                  = var.vpc_id
  subnet_id               = var.subnet_id
  container_network_type  = var.container_network_type
  container_network_cidr  = local.is_turbo ? null : var.container_cidr
  kubernetes_svc_ip_range = var.service_cidr
  authentication_mode     = "rbac"
  kube_proxy_mode         = var.kube_proxy_mode
  security_group_id       = opentelekomcloud_networking_secgroup_v2.this.id
  eip                     = var.bind_eip ? opentelekomcloud_vpc_eip_v1.cce_api[0].publicip[0].ip_address : null

  # ENI/Yangtse settings (CCE Turbo only)
  eni_subnet_id   = local.is_turbo ? var.eni_subnet_id : null
  eni_subnet_cidr = local.is_turbo ? var.eni_subnet_cidr : null

  enable_volume_encryption = var.master_volume_encryption

  api_access_trustlist = length(var.api_access_trustlist) > 0 ? var.api_access_trustlist : null

  delete_all_storage = tostring(var.delete_all_storage)
  delete_all_network = tostring(var.delete_all_network)

  dynamic "component_configurations" {
    for_each = var.component_configurations
    content {
      name = component_configurations.key
      dynamic "configurations" {
        for_each = component_configurations.value
        content {
          name  = configurations.key
          value = configurations.value
        }
      }
    }
  }

  dynamic "masters" {
    for_each = var.high_availability ? var.availability_zones : []
    content {
      availability_zone = masters.value
    }
  }

  timeouts {
    create = var.cluster_create_timeout
    delete = var.cluster_delete_timeout
  }

  depends_on = [opentelekomcloud_identity_agency_v3.cce]
}
