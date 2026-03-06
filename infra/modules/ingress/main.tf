terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
  }
}

# =============================================================================
# Ingress Controller (nginx-ingress CCE addon) + ELB
# =============================================================================

variable "cluster_id" { type = string }
variable "subnet_id" { type = string }
variable "vpc_id" { type = string }
variable "name_prefix" { type = string }

variable "create_ingress" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "nginx_ingress_version" {
  type    = string
  default = "5.0.2"
}

variable "nginx_ingress_controller_tag" {
  type        = string
  description = "Full image tag: v<controller>_<addon>. Check addontemplates API for correct mapping."
  default     = "v1.13.0_5.0.2"
}

# --- EIP ---
resource "opentelekomcloud_vpc_eip_v1" "ingress" {
  count = var.create_ingress ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-ingress-bw"
    size       = 100
    share_type = "PER"
  }

  tags = var.tags
}

# --- ELB (classic) ---
resource "opentelekomcloud_lb_loadbalancer_v2" "ingress" {
  count = var.create_ingress ? 1 : 0

  name          = "${var.name_prefix}-ingress-elb"
  vip_subnet_id = var.subnet_id
  tags          = var.tags
}

# --- Bind EIP to ELB ---
resource "opentelekomcloud_networking_floatingip_associate_v2" "ingress" {
  count = var.create_ingress ? 1 : 0

  floating_ip = opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address
  port_id     = opentelekomcloud_lb_loadbalancer_v2.ingress[0].vip_port_id
}

# --- nginx-ingress addon ---
resource "opentelekomcloud_cce_addon_v3" "ingress" {
  count = var.create_ingress ? 1 : 0

  cluster_id       = var.cluster_id
  template_name    = "nginx-ingress"
  template_version = var.nginx_ingress_version

  values {
    basic_json = jsonencode({
      swr_addr = "swr.eu-de.otc.t-systems.com"
      swr_user = "cce-addons"
      tag      = var.nginx_ingress_controller_tag
    })
    custom_json = jsonencode({
      namespace = "kube-system"
      service = {
        annotations = {
          "kubernetes.io/elb.id" = opentelekomcloud_lb_loadbalancer_v2.ingress[0].id
        }
      }
    })
    flavor_json = jsonencode({
      description = "custom resources"
      name        = "custom-resources"
      replicas    = 2
      resources = [
        {
          name        = "cceaddon-nginx-ingress-controller"
          limitsCpu   = "2000m"
          limitsMem   = "2000Mi"
          requestsCpu = "500m"
          requestsMem = "512Mi"
          replicas    = 2
        },
        {
          name        = "cceaddon-nginx-ingress-default-backend"
          limitsCpu   = "500m"
          limitsMem   = "500Mi"
          requestsCpu = "100m"
          requestsMem = "128Mi"
          replicas    = 1
        }
      ]
    })
  }

  depends_on = [
    opentelekomcloud_lb_loadbalancer_v2.ingress,
    opentelekomcloud_networking_floatingip_associate_v2.ingress
  ]
}

output "ingress_addon_id" {
  value = var.create_ingress ? opentelekomcloud_cce_addon_v3.ingress[0].id : null
}

output "elb_public_ip" {
  value = var.create_ingress ? opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address : null
}

# --- DNS A record (wildcard) ---
variable "zone_id" {
  type    = string
  default = ""
}

variable "zone_name" {

  type = string

  default = ""

}

variable "create_dns_record" {
  type    = bool
  default = false
}

resource "opentelekomcloud_dns_recordset_v2" "wildcard" {
  count = var.create_ingress && var.create_dns_record ? 1 : 0

  zone_id = var.zone_id
  name    = "*.${var.zone_name}"
  type    = "A"
  ttl     = 300
  records = [opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address]
}
