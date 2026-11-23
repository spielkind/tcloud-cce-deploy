# =============================================================================
# General
# =============================================================================
variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "otc_project_name" {
  description = "Project name used to scope IAM roles to the tenant project"
  type        = string
}

variable "region" {
  description = "OTC region"
  type        = string
  default     = "eu-de"
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# VPC
# =============================================================================
variable "vpc_cidr" {
  description = "OpenBao VPC CIDR block"
  type        = string
  default     = "10.1.0.0/16"
}

variable "subnet_cidr" {
  description = "OpenBao subnet CIDR (must be within vpc_cidr)"
  type        = string
  default     = "10.1.1.0/24"
}

variable "vpc_dns_list" {
  description = "DNS servers for the OpenBao VPC"
  type        = list(string)
  default     = ["100.125.4.25", "100.125.129.199"]
}

# =============================================================================
# Compute
# =============================================================================
variable "availability_zones" {
  description = "Availability zones for OpenBao ECS instances (one instance per AZ)"
  type        = list(string)
  default     = ["eu-de-01", "eu-de-02", "eu-de-03"]
}

variable "ecs_flavor" {
  description = "ECS flavor for OpenBao instances"
  type        = string
  default     = "s3.large.2"
}

variable "image_name" {
  description = "ECS image name (used when image_id is empty)"
  type        = string
  default     = "Standard_Ubuntu_22.04_latest"
}

variable "image_id" {
  description = "ECS image ID (overrides image_name if set)"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key for OpenBao ECS nodes and the bastion (recommended). Empty = generate an RSA key whose private key is stored in state."
  type        = string
  default     = ""
}

variable "evs_size" {
  description = "EVS SSD volume size in GB for Raft data storage"
  type        = number
  default     = 20
}

# =============================================================================
# OpenBao
# =============================================================================
variable "openbao_version" {
  description = "OpenBao version to install"
  type        = string
  default     = "2.7.3"
}

# =============================================================================
# ELB EIP
# =============================================================================
variable "elb_eip_bandwidth" {
  description = "ELB EIP bandwidth in Mbit/s"
  type        = number
  default     = 1000
}

# =============================================================================
# Bastion Host
# =============================================================================
variable "enable_bastion" {
  description = "Deploy a bastion host with EIP for SSH access to OpenBao nodes"
  type        = bool
  default     = true
}

variable "bastion_flavor" {
  description = "ECS flavor for the bastion host"
  type        = string
  default     = "s3.medium.2"
}

variable "bastion_ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH into the bastion host"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.bastion_ssh_allowed_cidrs : try(cidrhost(c, 0) != "" && tonumber(split("/", c)[1]) > 0, false)])
    error_message = "bastion_ssh_allowed_cidrs entries must be valid CIDRs with a non-zero prefix length (0.0.0.0/0 and ::/0 are not allowed)."
  }
}

variable "bastion_eip_bandwidth" {
  description = "Bastion EIP bandwidth in Mbit/s"
  type        = number
  default     = 10
}

# =============================================================================
# NAT
# =============================================================================
variable "nat_eip_bandwidth" {
  description = "NAT gateway EIP bandwidth in Mbit/s"
  type        = number
  default     = 1000
}

# =============================================================================
# TLS (BYO certificates — omit to use Let's Encrypt)
# =============================================================================
variable "tls_cert_pem" {
  description = "TLS server certificate PEM for OpenBao API (empty = use Let's Encrypt)"
  type        = string
  default     = ""
}

variable "tls_key_pem" {
  description = "TLS server private key PEM (required when tls_cert_pem is set)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_ca_cert_pem" {
  description = "TLS CA certificate PEM (required when tls_cert_pem is set)"
  type        = string
  default     = ""
}

variable "tls_fqdn" {
  description = "FQDN for BYO TLS connections (must match certificate CN/SAN, DNS resolution managed externally)"
  type        = string
  default     = ""
}

# =============================================================================
# Auto-Unseal (OTC DEW KMS)
# =============================================================================
variable "enable_auto_unseal" {
  description = "Enable KMS-based auto-unseal via OTC DEW. Creates an IAM agency for VMs with KMS + OBS permissions."
  type        = bool
  default     = true
}

variable "kms_admin_role_name" {
  description = "Existing project role that grants KMS access to the OpenBao ECS agency"
  type        = string
  default     = "KMS Administrator"
}

# =============================================================================
# Public DNS Recordset
# =============================================================================
variable "public_dns_zone_id" {
  description = "Public DNS zone ID for creating DNS records"
  type        = string
  default     = ""
}

variable "public_dns_record_name" {
  description = "FQDN for the public A record and OpenBao API"
  type        = string
  default     = ""
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to access the public OpenBao API through the TCP pass-through ELB"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.api_allowed_cidrs : try(cidrhost(c, 0) != "" && tonumber(split("/", c)[1]) > 0, false)])
    error_message = "api_allowed_cidrs entries must be valid CIDRs with a non-zero prefix length (0.0.0.0/0 and ::/0 are not allowed)."
  }
}

variable "enable_public_dns_record" {
  description = "Create a public A record for the OpenBao ELB"
  type        = bool
  default     = false
}

# =============================================================================
# Let's Encrypt Certificate (DNS-01 challenge via OTC DNS)
# =============================================================================
variable "enable_letsencrypt" {
  description = "Deploy certbot and OTC DNS hooks on bastion for Let's Encrypt certificates. Automatically disabled when BYO TLS certificates are provided."
  type        = bool
  default     = true
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt registration and expiry notifications"
  type        = string
  default     = ""
}

# =============================================================================
# LTS Logging (ICAgent → Log Tank Service)
# =============================================================================
variable "enable_lts_logging" {
  description = "Install ICAgent on all VMs and ship logs (audit, auth, syslog, cloud-init) to OTC LTS"
  type        = bool
  default     = true
}

variable "lts_ttl_days" {
  description = "Log retention in days for the OpenBao LTS log group (1-365)"
  type        = number
  default     = 90

  validation {
    condition     = var.lts_ttl_days >= 1 && var.lts_ttl_days <= 365
    error_message = "lts_ttl_days must be between 1 and 365."
  }
}

variable "allow_cce_nat_cidr" {
  description = "Allow cce_nat_cidr to reach the API (separate flag because the CIDR is unknown at plan time)"
  type        = bool
  default     = false
}

variable "cce_nat_cidr" {
  description = "CCE NAT EIP as /32; do not repeat it in api_allowed_cidrs (duplicate security group rule)"
  type        = string
  default     = ""
}
