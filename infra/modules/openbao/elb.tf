# =============================================================================
# ELB — OpenBao API :8200 + :443
# =============================================================================
resource "opentelekomcloud_lb_loadbalancer_v2" "this" {
  name          = "${var.name_prefix}-openbao-elb"
  vip_subnet_id = opentelekomcloud_vpc_subnet_v1.this.subnet_id
}

resource "opentelekomcloud_lb_listener_v2" "this" {
  name                         = "${var.name_prefix}-openbao-listener"
  loadbalancer_id              = opentelekomcloud_lb_loadbalancer_v2.this.id
  protocol                     = "TCP"
  protocol_port                = 8200
  transparent_client_ip_enable = true
}

resource "opentelekomcloud_lb_listener_v2" "https" {
  name                         = "${var.name_prefix}-openbao-listener-https"
  loadbalancer_id              = opentelekomcloud_lb_loadbalancer_v2.this.id
  protocol                     = "TCP"
  protocol_port                = 443
  transparent_client_ip_enable = true
}

resource "opentelekomcloud_lb_pool_v2" "this" {
  name        = "${var.name_prefix}-openbao-pool"
  listener_id = opentelekomcloud_lb_listener_v2.this.id
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
}

resource "opentelekomcloud_lb_pool_v2" "https" {
  name        = "${var.name_prefix}-openbao-pool-https"
  listener_id = opentelekomcloud_lb_listener_v2.https.id
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
}

resource "opentelekomcloud_lb_member_v2" "this" {
  count         = length(var.availability_zones)
  pool_id       = opentelekomcloud_lb_pool_v2.this.id
  address       = local.node_ips[count.index]
  protocol_port = 8200
  subnet_id     = opentelekomcloud_vpc_subnet_v1.this.subnet_id

  lifecycle {
    replace_triggered_by = [opentelekomcloud_ecs_instance_v1.this[count.index].id]
  }
}

resource "opentelekomcloud_lb_member_v2" "https" {
  count         = length(var.availability_zones)
  pool_id       = opentelekomcloud_lb_pool_v2.https.id
  address       = local.node_ips[count.index]
  protocol_port = 8200
  subnet_id     = opentelekomcloud_vpc_subnet_v1.this.subnet_id

  lifecycle {
    replace_triggered_by = [opentelekomcloud_ecs_instance_v1.this[count.index].id]
  }
}

resource "opentelekomcloud_lb_monitor_v2" "this" {
  name        = "${var.name_prefix}-openbao-monitor"
  pool_id     = opentelekomcloud_lb_pool_v2.this.id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}

resource "opentelekomcloud_lb_monitor_v2" "https" {
  name        = "${var.name_prefix}-openbao-monitor-https"
  pool_id     = opentelekomcloud_lb_pool_v2.https.id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}

# =============================================================================
# EIP for ELB (public access)
# =============================================================================
resource "opentelekomcloud_vpc_eip_v1" "elb" {
  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-openbao-elb-bw"
    size       = var.elb_eip_bandwidth
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_networking_floatingip_associate_v2" "elb" {
  floating_ip = opentelekomcloud_vpc_eip_v1.elb.publicip[0].ip_address
  port_id     = opentelekomcloud_lb_loadbalancer_v2.this.vip_port_id
}
