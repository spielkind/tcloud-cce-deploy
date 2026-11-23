# =============================================================================
# Image
# =============================================================================
data "opentelekomcloud_images_image_v2" "this" {
  count       = var.image_id == "" ? 1 : 0
  name        = var.image_name
  most_recent = true
}

locals {
  image_id = var.image_id != "" ? var.image_id : data.opentelekomcloud_images_image_v2.this[0].id
}

# =============================================================================
# SSH Keypair
# =============================================================================
resource "tls_private_key" "this" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "opentelekomcloud_compute_keypair_v2" "this" {
  name       = "${var.name_prefix}-openbao-key"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.this[0].public_key_openssh
}

# =============================================================================
# KMS Key for ECS disk encryption (always created, independent of auto-unseal)
# =============================================================================
resource "opentelekomcloud_kms_key_v1" "disk" {
  key_alias       = "${var.name_prefix}-openbao-disk-${random_id.obs_suffix.hex}"
  key_description = "Encryption key for OpenBao ECS system and data disks"
  is_enabled      = true
  pending_days    = 7

  # PSA Req 34: CMK must be rotated annually
  rotation_enabled  = true
  rotation_interval = 365
}

# =============================================================================
# EVS Data Volumes (separate from VMs to persist Raft data across VM recreation)
# =============================================================================
resource "opentelekomcloud_evs_volume_v3" "this" {
  count             = length(var.availability_zones)
  name              = "${var.name_prefix}-openbao-data-${count.index}"
  volume_type       = "SSD"
  size              = var.evs_size
  availability_zone = var.availability_zones[count.index]
  kms_id            = opentelekomcloud_kms_key_v1.disk.id
  tags              = var.tags
}

# =============================================================================
# ECS Instances
# =============================================================================
resource "opentelekomcloud_ecs_instance_v1" "this" {
  count             = length(var.availability_zones)
  name              = "${var.name_prefix}-openbao-${count.index}"
  flavor            = var.ecs_flavor
  image_id          = local.image_id
  availability_zone = var.availability_zones[count.index]
  key_name          = opentelekomcloud_compute_keypair_v2.this.name
  vpc_id            = opentelekomcloud_vpc_v1.this.id
  security_groups   = [opentelekomcloud_networking_secgroup_v2.this.id]

  nics {
    network_id = opentelekomcloud_vpc_subnet_v1.this.network_id
    ip_address = local.node_ips[count.index]
  }

  system_disk_type   = "SSD"
  system_disk_size   = 40
  system_disk_kms_id = opentelekomcloud_kms_key_v1.disk.id

  delete_disks_on_termination = false

  user_data = templatefile(
    "${path.module}/templates/user_data.sh.tftpl",
    {
      openbao_version = var.openbao_version
      node_id         = "openbao-${count.index}"
      node_ip         = local.node_ips[count.index]
      peer_ips        = [for j, ip in local.node_ips : ip if j != count.index]
      data_device     = "/dev/vdb"
      tls_ca_cert     = var.tls_ca_cert_pem
      tls_server_cert = var.tls_cert_pem
      tls_server_key  = var.tls_key_pem
      # Auto-unseal
      enable_auto_unseal = var.enable_auto_unseal
      kms_region         = var.region
      kms_key_id         = var.enable_auto_unseal ? opentelekomcloud_kms_key_v1.unseal[0].id : ""
      obs_bucket         = opentelekomcloud_obs_bucket.this.bucket
      agency_name        = opentelekomcloud_identity_agency_v3.openbao.name
      # Let's Encrypt TLS from OBS
      enable_letsencrypt = local.use_letsencrypt
      letsencrypt_domain = local.use_letsencrypt ? var.public_dns_record_name : ""
      fqdn               = local.fqdn
      obs_region         = var.region
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
    replace_triggered_by = [terraform_data.script_hashes.output["kms_py"]]

    precondition {
      condition     = local.use_letsencrypt || (var.tls_cert_pem != "" && var.tls_key_pem != "" && var.tls_ca_cert_pem != "" && var.tls_fqdn != "")
      error_message = "Either enable Let's Encrypt or provide tls_cert_pem, tls_key_pem, tls_ca_cert_pem, and tls_fqdn."
    }
  }
}

# =============================================================================
# Volume Attachments (link persistent data volumes to VMs)
# =============================================================================
resource "opentelekomcloud_compute_volume_attach_v2" "this" {
  count       = length(var.availability_zones)
  instance_id = opentelekomcloud_ecs_instance_v1.this[count.index].id
  volume_id   = opentelekomcloud_evs_volume_v3.this[count.index].id
}
