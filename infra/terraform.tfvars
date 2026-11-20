# =============================================================================
# Project
# =============================================================================
# otc_project_name comes from TF_VAR_otc_project_name (GitHub variable OTC_PROJECT_NAME)
name_prefix               = "test"
reuse_existing_cce_agency = true # cce_admin_trust already exists in this account
# region                  = "eu-de"             # default: eu-de

tags = {
  managed_by  = "terraform"
  project     = "test"
  environment = "test"
}

# =============================================================================
# Network
# =============================================================================
vpc_cidr        = "10.248.0.0/16"
subnet_cidr     = "10.248.0.0/24"   # Nodes (254 IPs)
eni_subnet_cidr = "10.248.128.0/18" # Pod ENIs (16k IPs, Yangtse only)
# vpc_dns_list  = ["100.125.4.25", "100.125.129.199"]  # default: OTC EU-DE DNS
# bastion_cidrs = []                            # default: no SSH access

# =============================================================================
# CCE Cluster
# =============================================================================
cluster_version        = "v1.35"
cluster_flavor         = "cce.s2.small" # s2 = HA (3 masters)
container_network_type = "eni"          # overlay_l2 | vpc-router | eni (Turbo/Yangtse)
high_availability      = true           # 3 masters across AZs
kube_proxy_mode        = "ipvs"
# cluster_type         = "VirtualMachine"        # default: VirtualMachine

# =============================================================================
# Node Pool
# =============================================================================
# Node flavors depend on container_network_type:
#   Standard (overlay_l2/vpc-router): s3, c4, m4, ...
#   Turbo (eni):                      s7n, c7n, m7n, c3n, ...  (network-enhanced)
node_flavor = "s7n.xlarge.2" # 4 vCPU, 8 GB RAM (Turbo-compatible)
# node_flavor       = "s3.xlarge.2"              # 4 vCPU, 8 GB RAM (Standard only)
# node_os           = "HCE OS 2.0"               # default: HCE OS 2.0
node_count          = 3
autoscaling_enabled = false
ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCqntLk7J/7hgeV0rNRsXQiEpRm+gI4CUo/proDV13aVHBYgqPLDFDWsiruIrM8ra7LfGOg5OBkQnE0if5ZITZXWVyo3YMD2CiN7o06az6CnhrYlYlTIVohzea5HLl7Psnf3en/uNkQehmBjUsJQaraJ7YXL09EuI27V/VNgzKlHGbyaH6DGqCNiswyFa39az3kS2cVQ+MAntWLQnGxymANTA+5bG5/0uri80b0Po+73DUqEg/2GQpxTr7ci8rXezB+jsDFzjC+qd+E5FeChqKNgN6RSxuOk4cQCbQdzyTie4JvnKLsBMJbHY3U1n65u9Ik+IwKlVWkdh7X4kHXSf9Z r.keutterling@telekom.de"

# =============================================================================
# DNS
# =============================================================================
create_dns    = true
dns_zone_name = "otc.nodefall.de."
dns_zone_type = "public"
# dns_zone_type = "private"                     # default: public

# =============================================================================
# Ingress
# =============================================================================
create_ingress = true
# Upgrade: check addontemplates API for version + tag mapping
# nginx_ingress_version        = "6.0.24"
# nginx_ingress_controller_tag = "v1.14.5_6.0.24"

# =============================================================================
# Access
# =============================================================================
bind_api_eip = true # Public kubectl access

# =============================================================================
# Logging (LTS)
# =============================================================================
create_lts = true
# log_agent_version = "1.7.10"                 # default: 1.7.10

# =============================================================================
# OpenBao Auto-Unseal
# =============================================================================
create_openbao_unseal = true

# =============================================================================
# Workload Identity (OIDC)
# =============================================================================
create_workload_identity = true
