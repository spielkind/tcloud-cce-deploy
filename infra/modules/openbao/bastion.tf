# =============================================================================
# Bastion Host — SSH jump host for OpenBao cluster management
# =============================================================================

# =============================================================================
# Security Group
# =============================================================================
resource "opentelekomcloud_networking_secgroup_v2" "bastion" {
  count       = var.enable_bastion ? 1 : 0
  name        = "${var.name_prefix}-openbao-bastion-sg"
  description = "OpenBao Bastion — SSH from allowed CIDRs"
}

resource "opentelekomcloud_networking_secgroup_rule_v2" "bastion_ssh" {
  count             = var.enable_bastion ? length(var.bastion_ssh_allowed_cidrs) : 0
  security_group_id = opentelekomcloud_networking_secgroup_v2.bastion[0].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.bastion_ssh_allowed_cidrs[count.index]
}

# =============================================================================
# ECS Instance
# =============================================================================
resource "opentelekomcloud_ecs_instance_v1" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  name              = "${var.name_prefix}-openbao-bastion"
  flavor            = var.bastion_flavor
  image_id          = local.image_id
  availability_zone = var.availability_zones[0]
  key_name          = opentelekomcloud_compute_keypair_v2.this.name
  vpc_id            = opentelekomcloud_vpc_v1.this.id
  security_groups   = [opentelekomcloud_networking_secgroup_v2.bastion[0].id]

  nics {
    network_id = opentelekomcloud_vpc_subnet_v1.this.network_id
  }

  system_disk_type   = "SSD"
  system_disk_size   = 40
  system_disk_kms_id = opentelekomcloud_kms_key_v1.disk.id

  user_data = templatefile(
    "${path.module}/templates/bastion_user_data.sh.tftpl",
    {
      openbao_version    = var.openbao_version
      tls_ca_cert        = var.tls_ca_cert_pem
      elb_vip            = opentelekomcloud_lb_loadbalancer_v2.this.vip_address
      fqdn               = local.fqdn
      node_ips           = local.node_ips
      enable_auto_unseal = var.enable_auto_unseal
      kms_region         = var.region
      kms_key_id         = var.enable_auto_unseal ? opentelekomcloud_kms_key_v1.unseal[0].id : ""
      obs_bucket         = opentelekomcloud_obs_bucket.this.bucket
      enable_letsencrypt = local.use_letsencrypt
      letsencrypt_domain = local.use_letsencrypt ? var.public_dns_record_name : ""
      letsencrypt_email  = var.letsencrypt_email
      le_dns_zone_id     = var.public_dns_zone_id
      # Shared scripts (downloaded from OBS at boot)
      obs_region = var.region
      # LTS logging
      enable_lts_logging = var.enable_lts_logging
      lts_region         = var.region
      name_prefix        = var.name_prefix
    }
  )

  metadata {
    agency_name = opentelekomcloud_identity_agency_v3.openbao.name
  }

  tags = var.tags

  lifecycle {
    replace_triggered_by = [
      terraform_data.script_hashes.output,
    ]
  }
}

# EIP (public access)
# =============================================================================
resource "opentelekomcloud_vpc_eip_v1" "bastion" {
  count = var.enable_bastion ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name       = "${var.name_prefix}-openbao-bastion-bw"
    size       = var.bastion_eip_bandwidth
    share_type = "PER"
  }

  tags = var.tags
}

resource "opentelekomcloud_networking_floatingip_associate_v2" "bastion" {
  count       = var.enable_bastion ? 1 : 0
  floating_ip = opentelekomcloud_vpc_eip_v1.bastion[0].publicip[0].ip_address
  port_id     = opentelekomcloud_ecs_instance_v1.bastion[0].nics[0].port_id
}
