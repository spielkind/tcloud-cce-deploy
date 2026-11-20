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
  value = module.security_group.security_group_id
}

output "keypair_name" {
  value = opentelekomcloud_compute_keypair_v2.this.name
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
  value       = module.ingress.elb_public_ip
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

output "openbao_unseal_obs_bucket" {
  value = module.openbao_unseal.obs_bucket
}

output "openbao_unseal_function_urn" {
  value = module.openbao_unseal.function_urn
}

output "workload_identity_provider_id" {
  value = module.workload_identity.provider_id
}

output "workload_identity_client_id" {
  value = module.workload_identity.client_id
}
