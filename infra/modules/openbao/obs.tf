# =============================================================================
# OBS Bucket — Unseal Key Storage + Raft Snapshots
# =============================================================================
# Shared random suffix for the bucket name and the KMS key aliases (a deleted
# key keeps its alias while pending deletion).
resource "random_id" "obs_suffix" {
  byte_length = 4
}

# KMS key in regional project (eu-de) — required for OBS server-side encryption
resource "opentelekomcloud_kms_key_v1" "obs" {
  provider        = opentelekomcloud.regional
  key_alias       = "${var.name_prefix}-openbao-obs-${random_id.obs_suffix.hex}"
  key_description = "Server-side encryption for OpenBao OBS bucket"
  is_enabled      = true
  pending_days    = 7

  # PSA Req 34: CMK must be rotated annually
  rotation_enabled  = true
  rotation_interval = 365
}

# force_destroy: the versioned bucket always holds scripts, keys and snapshots
# and would otherwise block `tofu destroy`. Its contents are SSE-KMS encrypted
# with a key destroyed in the same run, so they are unusable afterwards anyway;
# copy snapshots elsewhere first if they must outlive the cluster.
resource "opentelekomcloud_obs_bucket" "this" {
  bucket        = "${var.name_prefix}-openbao-${random_id.obs_suffix.hex}"
  acl           = "private"
  versioning    = true
  force_destroy = true
  tags          = var.tags

  server_side_encryption {
    algorithm  = "kms"
    kms_key_id = opentelekomcloud_kms_key_v1.obs.id
  }

  lifecycle_rule {
    name    = "openbao-cleanup"
    enabled = true
    noncurrent_version_expiration {
      days = 90
    }
    abort_incomplete_multipart_upload {
      days = 7
    }
  }
}

# =============================================================================
# Upload helper scripts to OBS (keeps user_data within size limits)
# =============================================================================
resource "opentelekomcloud_obs_bucket_object" "kms_py" {
  bucket  = opentelekomcloud_obs_bucket.this.bucket
  key     = "scripts/openbao-kms.py"
  content = file("${path.module}/files/openbao-kms.py")
}

resource "opentelekomcloud_obs_bucket_object" "dns_py" {
  count   = local.use_letsencrypt ? 1 : 0
  bucket  = opentelekomcloud_obs_bucket.this.bucket
  key     = "scripts/otc-dns.py"
  content = file("${path.module}/files/otc-dns.py")
}

resource "opentelekomcloud_obs_bucket_object" "restore_sh" {
  bucket  = opentelekomcloud_obs_bucket.this.bucket
  key     = "scripts/bao-restore.sh"
  content = file("${path.module}/files/bao-restore.sh")
}

# Track script content hashes — used by replace_triggered_by to recreate
# VMs when scripts change (OBS object IDs are stable, so we hash locally)
resource "terraform_data" "script_hashes" {
  input = {
    kms_py     = filemd5("${path.module}/files/openbao-kms.py")
    restore_sh = filemd5("${path.module}/files/bao-restore.sh")
    dns_py     = local.use_letsencrypt ? filemd5("${path.module}/files/otc-dns.py") : ""
  }
}
