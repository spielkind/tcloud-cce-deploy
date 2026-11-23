# =============================================================================
# dev — self-contained environment configuration
#   tofu init  -backend-config=envs/dev.backend.tfvars
#   tofu apply -var-file=envs/dev.tfvars
# Credentials and otc_project_name come from TF_VAR_* environment variables.
# =============================================================================
environment                   = "dev"
name_prefix                   = "test"
region                        = "eu-de"
availability_zones            = ["eu-de-01", "eu-de-02", "eu-de-03"]
reuse_existing_cce_agency     = true # cce_admin_trust already exists in the account
reuse_existing_evs_kms_agency = true # EVSAccessKMS already exists in the account

tags = {
  managed_by = "terraform"
  project    = "test"
}

# --- Network ---
vpc_cidr          = "10.248.0.0/16"
subnet_cidr       = "10.248.0.0/24"
eni_subnet_cidr   = "10.248.128.0/18" # pod ENIs, inside vpc_cidr
service_cidr      = "10.247.0.0/16"
nat_spec          = "1"
nat_eip_bandwidth = 100
bastion_cidrs     = []
nodeport_cidrs    = [] # automatic: vpc_cidr (eni mode)

# --- Cluster (CCE Turbo) ---
cluster_version          = "v1.35"
cluster_flavor           = "cce.s2.small"
container_network_type   = "eni"
high_availability        = true
kube_proxy_mode          = "ipvs"
bind_api_eip             = true
api_eip_bandwidth        = 10
api_access_trustlist     = []
master_volume_encryption = true # EVSAccessKMS has KMS Administrator in this project
delete_all_storage       = true
delete_all_network       = true

# --- Nodes ---
ssh_public_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCqntLk7J/7hgeV0rNRsXQiEpRm+gI4CUo/proDV13aVHBYgqPLDFDWsiruIrM8ra7LfGOg5OBkQnE0if5ZITZXWVyo3YMD2CiN7o06az6CnhrYlYlTIVohzea5HLl7Psnf3en/uNkQehmBjUsJQaraJ7YXL09EuI27V/VNgzKlHGbyaH6DGqCNiswyFa39az3kS2cVQ+MAntWLQnGxymANTA+5bG5/0uri80b0Po+73DUqEg/2GQpxTr7ci8rXezB+jsDFzjC+qd+E5FeChqKNgN6RSxuOk4cQCbQdzyTie4JvnKLsBMJbHY3U1n65u9Ik+IwKlVWkdh7X4kHXSf9Z r.keutterling@telekom.de"
node_os                = "HCE OS 2.0"
node_runtime           = "containerd"
node_root_volume_type  = "SSD"
node_data_volume_type  = "SSD"
node_volume_encryption = true # EVSAccessKMS has KMS Administrator in this project

# Pool name = <name_prefix>-<key>. gpu = true adds the NVIDIA addon and the
# default label accelerator=nvidia + taint nvidia.com/gpu=present:NoSchedule.
node_pools = {
  pool = {
    flavor = "s7n.xlarge.2" # 4 vCPU, 8 GB, Turbo-compatible
    count  = 3
  }
  gpu = {
    flavor           = "pi5e.2xlarge.4" # 1x NVIDIA L4 24 GB
    gpu              = true
    autoscaling      = true # scale 0..1: a node only exists while a GPU pod needs it
    min_count        = 0
    max_count        = 1
    az               = "eu-de-01" # GPU capacity differs per AZ; eu-de-03 as fallback
    root_volume_size = 100        # driver installation needs headroom
  }
}

# --- Addons ---
create_metrics_server = true
create_ingress        = true
ingress_eip_bandwidth = 100
create_lts            = true
lts_ttl_days          = 7

# --- DNS (public zone managed by this stack) ---
create_dns    = true
dns_zone_name = "tcloud.conmob.t-systems.net."
dns_zone_type = "public"

# --- Audit / logging ---
# CTS: one system tracker per project (the project has none yet); traces to OBS (KMS) and LTS.
create_cts_tracker   = true
cts_retention_days   = 90
cts_lts_enabled      = true
vpc_flow_log_enabled = false # opt-in: flow log of the cluster VPC -> LTS

# --- OpenBao / workload identity ---
openbao_mode             = "cce"
create_openbao_unseal    = true
create_workload_identity = true

# Optional dedicated VM OpenBao settings (openbao_mode = "vm"). Never commit
# private keys here; prefer Let's Encrypt (enable_letsencrypt = true).
openbao_vm = {
  subnet_cidr              = "10.249.1.0/24"
  vpc_cidr                 = "10.249.0.0/16"
  availability_zones       = ["eu-de-01", "eu-de-02", "eu-de-03"]
  ecs_flavor               = "s3.large.2"
  image_name               = "Standard_Ubuntu_22.04_latest"
  evs_size                 = 20
  version                  = "2.7.3"
  fqdn                     = ""
  public_dns_zone_id       = ""
  enable_public_dns_record = false
  api_allowed_cidrs        = []
  tls_cert_pem             = ""
  tls_key_pem              = ""
  tls_ca_cert_pem          = ""
  tls_fqdn                 = ""
  enable_auto_unseal       = true
  kms_admin_role_name      = "KMS Administrator"
  enable_bastion           = true
  bastion_allowed_cidrs    = []
  enable_letsencrypt       = false
  letsencrypt_email        = ""
  enable_lts_logging       = true
  lts_ttl_days             = 30
  elb_eip_bandwidth        = 100
  nat_eip_bandwidth        = 100
  bastion_eip_bandwidth    = 10
}
