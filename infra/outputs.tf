output "vpc_id" {
  value = module.vpc.vpc_id
}

output "subnet_id" {
  value = module.vpc.subnet_network_id
}

output "cce_cluster_id" {
  value = module.cce.cluster_id
}

output "cce_cluster_name" {
  value = module.cce.cluster_name
}

output "cce_api_endpoint" {
  value = module.cce.cluster_api_endpoint
}

output "security_group_id" {
  value = module.cce.security_group_id
}

output "keypair_name" {
  value = module.cce.keypair_name
}

output "ssh_private_key_pem" {
  description = "Generated worker SSH private key (null when ssh_public_key is set)"
  value       = module.cce.ssh_private_key_pem
  sensitive   = true
}

output "node_pool_ids" {
  description = "Node pool IDs keyed by node_pools key"
  value       = module.cce.node_pool_ids
}

output "node_volume_kms_key_id" {
  description = "KMS key ID encrypting worker volumes (null if disabled)"
  value       = module.cce.node_volume_kms_key_id
}

output "lts_group_id" {
  description = "Cluster LTS log group ID (empty if create_lts is false)"
  value       = module.cce.lts_group_id
}

output "lts_hostfile_stream_id" {
  description = "Cluster LTS stream for node log files (empty if create_lts is false)"
  value       = module.cce.lts_hostfile_stream_id
}

output "addon_versions" {
  description = "Resolved CCE addon versions"
  value       = module.cce.addon_versions
}

output "nat_public_ip" {
  description = "Outbound (SNAT) public IP of the cluster"
  value       = module.nat.nat_public_ip
}

output "cts_audit_bucket" {
  description = "OBS bucket receiving CTS audit traces (null unless create_cts_tracker)"
  value       = var.create_cts_tracker ? opentelekomcloud_obs_bucket.audit[0].bucket : null
}

output "environment" {
  value = var.environment
}

output "kubeconfig" {
  description = "Kubeconfig YAML — save with: terraform output -raw kubeconfig > ~/.kube/config"
  sensitive   = true
  value = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = module.cce.cluster_name
      cluster = {
        server                     = module.cce.cluster_api_public_ip != null ? "https://${module.cce.cluster_api_public_ip}:5443" : module.cce.cluster_api_endpoint
        certificate-authority-data = module.cce.cluster_ca_cert
      }
    }]
    users = [{
      name = "admin"
      user = {
        client-certificate-data = module.cce.client_cert
        client-key-data         = module.cce.client_key
      }
    }]
    contexts = [{
      name = module.cce.cluster_name
      context = {
        cluster = module.cce.cluster_name
        user    = "admin"
      }
    }]
    current-context = module.cce.cluster_name
  })
}

output "ingress_elb_public_ip" {
  description = "Public IP of the ingress ELB"
  value       = module.cce.ingress_elb_public_ip
}

output "cluster_ca_cert" {
  value     = module.cce.cluster_ca_cert
  sensitive = true
}

output "client_cert" {
  value     = module.cce.client_cert
  sensitive = true
}

output "client_key" {
  value     = module.cce.client_key
  sensitive = true
}

output "dns_zone_name" {
  value = var.dns_zone_name
}

output "cce_api_endpoint_public" {
  description = "CCE API endpoint (public if EIP bound, else internal)"
  value       = module.cce.cluster_api_public_ip != null ? "https://${module.cce.cluster_api_public_ip}:5443" : module.cce.cluster_api_endpoint
}

output "swr_organization" {
  value = module.swr.organization
}

output "swr_endpoint" {
  value = module.swr.endpoint
}

# --- OpenBao Auto-Unseal ---
output "otc_project_name" {
  value = var.otc_project_name
}

output "openbao_unseal_kms_key_id" {
  value = module.openbao_unseal.kms_key_id
}

output "workload_identity_provider_id" {
  value = module.workload_identity.provider_id
}

output "workload_identity_client_id" {
  value = module.workload_identity.client_id
}

output "gpu_node_pool_enabled" {
  description = "True if at least one node pool has gpu = true"
  value       = module.cce.gpu_enabled
}

output "gpu_xgpu_enabled" {
  description = "True if GPU slicing (CCE xGPU + Volcano) is enabled; workloads use it as gpu_slicing default"
  value       = module.cce.xgpu_enabled
}

output "gpu_node_selector" {
  description = "nodeSelector for GPU workloads (labels of the first GPU pool)"
  value       = module.cce.gpu_node_selector
}

output "gpu_node_tolerations" {
  description = "Tolerations for GPU workloads (taints of the first GPU pool)"
  value       = module.cce.gpu_node_tolerations
}

output "openbao_mode" {
  value = var.openbao_mode
}

output "openbao_vm_url" {
  description = "VM-based OpenBao URL (empty unless openbao_mode is vm)"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].url : ""
}

output "openbao_vm_ca_cert" {
  description = "CA certificate of the VM-based OpenBao (empty with Let's Encrypt or unless openbao_mode is vm)"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].ca_cert_pem : ""
}

output "openbao_vm_nat_public_ip" {
  description = "Outbound IP of the OpenBao VMs (allow it where the CCE API access is restricted)"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].nat_public_ip : null
}

output "openbao_vm_ssh_private_key" {
  description = "Private SSH key only when generated by the VM module"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].ssh_private_key_pem : null
  sensitive   = true
}

output "openbao_vm_bastion_public_ip" {
  description = "Public IP of the optional VM OpenBao bastion"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].bastion_public_ip : null
}

output "openbao_vm_elb_public_ip" {
  description = "VM-based OpenBao ELB public IP (null unless openbao_mode is vm)"
  value       = var.openbao_mode == "vm" ? module.openbao_vm[0].elb_public_ip : null
}

output "region" {
  value = var.region
}
