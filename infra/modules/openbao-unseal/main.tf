terraform {
  required_providers {
    opentelekomcloud = {
      source = "opentelekomcloud/opentelekomcloud"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "name_prefix" { type = string }
variable "create_openbao_unseal" {
  type    = bool
  default = false
}
variable "project_name" { type = string }
variable "namespace" {
  description = "Kubernetes namespace of the OpenBao server"
  type        = string
  default     = "openbao"
}
variable "service_account" {
  description = "ServiceAccount of the OpenBao server pods"
  type        = string
  default     = "openbao"
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "vpc_id" {
  description = "VPC ID for FunctionGraph VPC access"
  type        = string
  default     = ""
}
variable "enable_vpc_access" {
  description = "Enable VPC access for FunctionGraph (must not depend on resource attributes)"
  type        = bool
  default     = false
}
variable "subnet_id" {
  description = "Subnet network ID for FunctionGraph VPC access"
  type        = string
  default     = ""
}

# =============================================================================
# KMS Key for encrypting/decrypting OpenBao unseal keys
# =============================================================================
# Deleted KMS keys stay pending (with their alias) for 7 days, so the alias gets
# a random suffix to allow destroy + redeploy within that window.
resource "random_id" "kms_alias" {
  count       = var.create_openbao_unseal ? 1 : 0
  byte_length = 3
}

resource "opentelekomcloud_kms_key_v1" "openbao" {
  count = var.create_openbao_unseal ? 1 : 0

  key_alias       = "${var.name_prefix}-openbao-unseal-${random_id.kms_alias[0].hex}"
  key_description = "Encrypts OpenBao unseal keys stored in OBS"
  pending_days    = 7
  is_enabled      = true
  tags            = var.tags
}

# =============================================================================
# OBS Bucket for storing encrypted unseal keys
# =============================================================================
resource "opentelekomcloud_obs_bucket" "openbao_unseal" {
  count = var.create_openbao_unseal ? 1 : 0

  bucket        = "${var.name_prefix}-openbao-unseal"
  acl           = "private"
  versioning    = true
  force_destroy = true

  lifecycle_rule {
    name    = "cleanup-old-versions"
    enabled = true
    prefix  = ""

    noncurrent_version_expiration {
      days = 30
    }
  }

  tags = var.tags
}

# =============================================================================
# Custom KMS policy (decrypt only)
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "kms_decrypt" {
  count = var.create_openbao_unseal ? 1 : 0

  description   = "Decrypt data via KMS"
  display_name  = "${var.name_prefix}-kms-decrypt"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "kms:cmk:get",
      "kms:cmk:crypto",
    ]
  }
}

# =============================================================================
# Custom OBS policy (GetObject only)
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "obs_object_read" {
  count = var.create_openbao_unseal ? 1 : 0

  description   = "Read objects from OBS buckets"
  display_name  = "${var.name_prefix}-obs-object-read"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "obs:bucket:ListAllMyBuckets",
      "obs:bucket:ListBucket",
      "obs:bucket:HeadBucket",
      "obs:object:GetObject",
      "obs:bucket:GetBucketLocation",
    ]
  }
}

# =============================================================================
# Custom VPC policy (FunctionGraph VPC access)
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "fg_vpc_access" {
  count = var.create_openbao_unseal && var.enable_vpc_access ? 1 : 0

  description   = "Minimal VPC permissions for FunctionGraph VPC access"
  display_name  = "${var.name_prefix}-fg-vpc-access"
  display_layer = "project"

  statement {
    effect = "Allow"
    action = [
      "vpc:vpcs:get",
      "vpc:publicIps:get",
      "vpc:ports:get",
      "vpc:ports:create",
      "vpc:ports:update",
      "vpc:subnets:get",
    ]
  }
}

# =============================================================================
# IAM Agency for FunctionGraph (KMS decrypt + OBS read)
# =============================================================================
resource "opentelekomcloud_identity_agency_v3" "openbao_unseal" {
  count = var.create_openbao_unseal ? 1 : 0

  name                  = "${var.name_prefix}-openbao-unseal"
  description           = "FunctionGraph agency for OpenBao auto-unseal (KMS decrypt + OBS read)"
  delegated_domain_name = "op_svc_cff"

  project_role {
    all_projects = true
    roles = [
      opentelekomcloud_identity_role_v3.obs_object_read[0].display_name,
    ]
  }

  project_role {
    project = var.project_name
    roles = compact([
      opentelekomcloud_identity_role_v3.kms_decrypt[0].display_name,
      var.enable_vpc_access ? opentelekomcloud_identity_role_v3.fg_vpc_access[0].display_name : "",
    ])
  }
}

# =============================================================================
# FunctionGraph: OpenBao unseal function
# =============================================================================
resource "opentelekomcloud_fgs_function_v2" "openbao_unseal" {
  count = var.create_openbao_unseal ? 1 : 0

  name        = "${var.name_prefix}-openbao-unseal"
  app         = "default"
  agency      = opentelekomcloud_identity_agency_v3.openbao_unseal[0].name
  description = "Reads encrypted OpenBao unseal keys from OBS and decrypts via KMS"
  handler     = "index.handler"
  memory_size = 128
  timeout     = 90
  runtime     = "Python3.12"
  code_type   = "inline"

  func_code = base64encode(file("${path.module}/function/index.py"))

  user_data = jsonencode({
    bucket     = opentelekomcloud_obs_bucket.openbao_unseal[0].bucket
    object_key = "openbao-unseal/keys.enc"
  })

  vpc_id     = var.vpc_id
  network_id = var.subnet_id

  tags = var.tags
}

# =============================================================================
# Outputs
# =============================================================================
output "kms_key_id" {
  description = "KMS key ID for OpenBao unseal encryption"
  value       = var.create_openbao_unseal ? opentelekomcloud_kms_key_v1.openbao[0].id : ""
}

output "kms_key_arn" {
  description = "KMS key domain-scoped ID"
  value       = var.create_openbao_unseal ? opentelekomcloud_kms_key_v1.openbao[0].domain_id : ""
}

output "obs_bucket" {
  description = "OBS bucket name for encrypted unseal keys"
  value       = var.create_openbao_unseal ? opentelekomcloud_obs_bucket.openbao_unseal[0].bucket : ""
}

output "obs_bucket_endpoint" {
  description = "OBS bucket domain name"
  value       = var.create_openbao_unseal ? opentelekomcloud_obs_bucket.openbao_unseal[0].bucket_domain_name : ""
}

output "function_urn" {
  description = "FunctionGraph function URN"
  value       = var.create_openbao_unseal ? opentelekomcloud_fgs_function_v2.openbao_unseal[0].urn : ""
}

output "agency_name" {
  description = "IAM agency name for FunctionGraph"
  value       = var.create_openbao_unseal ? opentelekomcloud_identity_agency_v3.openbao_unseal[0].name : ""
}

# =============================================================================
# Workload Identity: FG Invoke Policy
# =============================================================================
resource "opentelekomcloud_identity_role_v3" "fg_invoke" {
  count         = var.create_openbao_unseal ? 1 : 0
  description   = "FunctionGraph read + invoke (OpenBao auto-unseal)"
  display_name  = "${var.name_prefix}-fg-invoke"
  display_layer = "project"
  statement {
    effect = "Allow"
    action = [
      "functiongraph:*:get*",
      "functiongraph:*:list*",
      "functiongraph:function:invoke*",
    ]
  }
}

output "workload" {
  description = "Workload identity definition for OpenBao (namespace, SA, role IDs)"
  value = var.create_openbao_unseal ? {
    namespace       = var.namespace
    service_account = var.service_account
    role_ids        = [opentelekomcloud_identity_role_v3.fg_invoke[0].id]
  } : null
}
