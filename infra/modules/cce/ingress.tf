resource "opentelekomcloud_vpc_eip_v1" "ingress" {
  count = var.create_ingress ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-ingress-bw"
    size       = var.ingress_eip_bandwidth
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_lb_loadbalancer_v2" "ingress" {
  count = var.create_ingress ? 1 : 0

  name          = "${var.name_prefix}-ingress-elb"
  vip_subnet_id = var.subnet_neutron_id
  tags          = var.tags
}

resource "opentelekomcloud_networking_floatingip_associate_v2" "ingress" {
  count = var.create_ingress ? 1 : 0

  floating_ip = opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address
  port_id     = opentelekomcloud_lb_loadbalancer_v2.ingress[0].vip_port_id
}

locals {
  # The nginx-ingress template does not expose the controller tag through the
  # addon templates data source (image_version is empty), so the tag variable
  # is used unless the template provides one.
  nginx_ingress_controller_tag = coalesce(
    try(local.addon_template["nginx-ingress"].image_version, ""),
    var.nginx_ingress_controller_tag,
  )
}

resource "opentelekomcloud_cce_addon_v3" "ingress" {
  count = var.create_ingress ? 1 : 0

  cluster_id       = opentelekomcloud_cce_cluster_v3.this.id
  template_name    = "nginx-ingress"
  template_version = local.addon_version["nginx-ingress"]

  values {
    basic_json = jsonencode({
      swr_addr = local.addon_swr_addr["nginx-ingress"]
      swr_user = local.addon_swr_user["nginx-ingress"]
      tag      = local.nginx_ingress_controller_tag
    })
    custom_json = jsonencode({
      namespace = "kube-system"
      service = {
        annotations = {
          "kubernetes.io/elb.id" = opentelekomcloud_lb_loadbalancer_v2.ingress[0].id
        }
        # Local keeps the client source IP; Cluster spreads load across all
        # controller replicas at the cost of SNAT.
        externalTrafficPolicy = var.ingress_preserve_client_ip ? "Local" : "Cluster"
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

  lifecycle {
    precondition {
      condition     = local.addon_version["nginx-ingress"] != null
      error_message = "No nginx-ingress addon template found for ${var.cluster_version}."
    }
    precondition {
      condition     = endswith(local.nginx_ingress_controller_tag, "_${coalesce(local.addon_version["nginx-ingress"], "-")}")
      error_message = "nginx_ingress_controller_tag must end with _<addon version> (resolved: ${coalesce(local.addon_version["nginx-ingress"], "none")}); look up spec.versions[].input.basic.tag via the CCE addontemplates API."
    }
  }

  depends_on = [
    opentelekomcloud_networking_floatingip_associate_v2.ingress,
    opentelekomcloud_cce_node_pool_v3.this
  ]
}

resource "opentelekomcloud_dns_recordset_v2" "wildcard" {
  count = var.create_ingress && var.create_dns_record ? 1 : 0

  zone_id = var.dns_zone_id
  name    = "*.${var.dns_zone_name}"
  type    = "A"
  ttl     = 300
  records = [opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address]
}
