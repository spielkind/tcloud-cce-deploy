output "cluster_id" {
  value = opentelekomcloud_cce_cluster_v3.this.id
}

output "cluster_name" {
  value = opentelekomcloud_cce_cluster_v3.this.name
}

output "cluster_api_endpoint" {
  description = "Internal (VPC) API endpoint"
  value       = opentelekomcloud_cce_cluster_v3.this.certificate_clusters[0].server
}

output "cluster_api_public_ip" {
  description = "Public API EIP (null if not bound)"
  value       = var.bind_eip ? try(opentelekomcloud_vpc_eip_v1.cce_api[0].publicip[0].ip_address, null) : null
}

output "cluster_ca_cert" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_clusters[0].certificate_authority_data
  sensitive = true
}

output "client_cert" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_users[0].client_certificate_data
  sensitive = true
}

output "client_key" {
  value     = opentelekomcloud_cce_cluster_v3.this.certificate_users[0].client_key_data
  sensitive = true
}

output "agency_name" {
  value = var.reuse_existing_cce_agency ? local.cce_agency_name : opentelekomcloud_identity_agency_v3.cce[0].name
}

output "node_pool_ids" {
  description = "Node pool IDs keyed by node_pools key"
  value       = { for name, pool in opentelekomcloud_cce_node_pool_v3.this : name => pool.id }
}

output "keypair_name" {
  value = opentelekomcloud_compute_keypair_v2.this.name
}

output "ssh_private_key_pem" {
  description = "Generated worker SSH private key (null when ssh_public_key is supplied)"
  value       = var.ssh_public_key == "" ? tls_private_key.ssh[0].private_key_pem : null
  sensitive   = true
}

output "node_volume_kms_key_id" {
  description = "KMS key ID used for worker volumes (null if encryption is disabled)"
  value       = local.node_volume_kms_id
}

output "security_group_id" {
  value = opentelekomcloud_networking_secgroup_v2.this.id
}

output "ingress_elb_public_ip" {
  value = var.create_ingress ? opentelekomcloud_vpc_eip_v1.ingress[0].publicip[0].ip_address : null
}

output "lts_group_id" {
  description = "LTS log group ID (empty if LTS is disabled)"
  value       = local.group_id
}

output "lts_hostfile_stream_id" {
  description = "LTS stream for node log files (empty if LTS is disabled)"
  value       = var.create_lts ? opentelekomcloud_lts_stream_v2.hostfile[0].id : ""
}

output "addon_versions" {
  description = "Resolved addon template versions (null for disabled addons)"
  value       = { for name, enabled in local.addon_enabled : name => enabled ? local.addon_version[name] : null }
}

output "gpu_enabled" {
  description = "True if at least one node pool has gpu = true"
  value       = local.gpu_enabled
}

output "gpu_node_selector" {
  description = "Kubernetes labels of the first GPU pool (for nodeSelector)"
  value       = local.gpu_enabled ? values(local.gpu_pools)[0].labels : {}
}

output "gpu_node_tolerations" {
  description = "Tolerations matching the taints of the first GPU pool"
  value = local.gpu_enabled ? [
    for t in values(local.gpu_pools)[0].taints : { key = t.key, operator = "Exists", effect = t.effect }
  ] : []
}
