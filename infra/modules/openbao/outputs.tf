# =============================================================================
# VPC
# =============================================================================
output "vpc_id" {
  description = "OpenBao VPC ID"
  value       = opentelekomcloud_vpc_v1.this.id
}

output "subnet_id" {
  description = "OpenBao subnet ID"
  value       = opentelekomcloud_vpc_subnet_v1.this.id
}

# =============================================================================
# ELB
# =============================================================================
output "elb_vip_address" {
  description = "OpenBao internal ELB VIP address (:443 and :8200 TCP pass-through)"
  value       = opentelekomcloud_lb_loadbalancer_v2.this.vip_address
}

output "elb_public_ip" {
  description = "OpenBao ELB public IP"
  value       = opentelekomcloud_vpc_eip_v1.elb.publicip[0].ip_address
}

# =============================================================================
# Compute
# =============================================================================
output "ecs_instance_ids" {
  description = "ECS instance IDs running OpenBao"
  value       = opentelekomcloud_ecs_instance_v1.this[*].id
}

output "ecs_private_ips" {
  description = "Private IPs of OpenBao ECS instances"
  value       = local.node_ips
}

output "nat_public_ip" {
  description = "Source IP of outbound traffic from the OpenBao VMs (e.g. allow it on the CCE API for Kubernetes auth)"
  value       = opentelekomcloud_vpc_eip_v1.nat.publicip[0].ip_address
}

output "security_group_id" {
  description = "OpenBao security group ID"
  value       = opentelekomcloud_networking_secgroup_v2.this.id
}

output "keypair_name" {
  description = "SSH keypair name for OpenBao ECS instances"
  value       = opentelekomcloud_compute_keypair_v2.this.name
}

# =============================================================================
# OBS
# =============================================================================
output "obs_bucket_name" {
  description = "OBS bucket name for Raft snapshot backups"
  value       = opentelekomcloud_obs_bucket.this.bucket
}

# =============================================================================
# Bastion
# =============================================================================
output "bastion_private_ip" {
  description = "Bastion host private IP (null when bastion is disabled)"
  value       = var.enable_bastion ? opentelekomcloud_ecs_instance_v1.bastion[0].nics[0].ip_address : null
}

output "bastion_public_ip" {
  description = "Bastion host public IP (null when bastion is disabled)"
  value       = var.enable_bastion ? opentelekomcloud_vpc_eip_v1.bastion[0].publicip[0].ip_address : null
}

# =============================================================================
# DNS + TLS
# =============================================================================
output "fqdn" {
  description = "OpenBao FQDN (Let's Encrypt domain or BYO TLS FQDN)"
  value       = local.fqdn
}

output "url" {
  description = "OpenBao URL through the public ELB"
  value       = "https://${local.fqdn}"
}

output "ssh_private_key_pem" {
  description = "Fallback auto-generated SSH private key PEM (null when ssh_public_key is supplied, which is recommended)"
  value       = var.ssh_public_key != "" ? null : tls_private_key.this[0].private_key_pem
  sensitive   = true
}

output "ca_cert_pem" {
  description = "BYO TLS CA certificate PEM for clients (empty with Let's Encrypt, which is publicly trusted)"
  value       = local.use_letsencrypt ? "" : var.tls_ca_cert_pem
}

# =============================================================================
# Auto-Unseal (KMS)
# =============================================================================
output "kms_key_id" {
  description = "OTC KMS key ID for auto-unseal (null when auto-unseal is disabled)"
  value       = var.enable_auto_unseal ? opentelekomcloud_kms_key_v1.unseal[0].id : null
}

output "agency_name" {
  description = "IAM agency name used by OpenBao VM nodes and the optional bastion"
  value       = opentelekomcloud_identity_agency_v3.openbao.name
}

# =============================================================================
# LTS Logging
# =============================================================================
output "lts_group_id" {
  description = "LTS log group ID for OpenBao logs (null when LTS logging is disabled)"
  value       = var.enable_lts_logging ? opentelekomcloud_lts_group_v2.openbao[0].id : null
}
