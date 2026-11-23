# KMS key for worker volume encryption. The alias carries a random suffix
# because a key pending deletion keeps its alias for pending_days.
resource "random_id" "kms" {
  count       = var.node_volume_encryption ? 1 : 0
  byte_length = 4
}

resource "opentelekomcloud_kms_key_v1" "node_volumes" {
  count = var.node_volume_encryption ? 1 : 0

  key_alias       = "${var.name_prefix}-node-volumes-${random_id.kms[0].hex}"
  key_description = "CCE node pool volume encryption key"
  pending_days    = 7
  is_enabled      = true

  rotation_enabled  = true
  rotation_interval = 365

  tags = var.tags
}

locals {
  node_volume_kms_id = var.node_volume_encryption ? opentelekomcloud_kms_key_v1.node_volumes[0].id : null
}
