# STATUS: template — prod is not configured yet. Fill in real values and remove this line to enable it.
# =============================================================================
# prod — self-contained environment configuration
#   export TF_VAR_environment=prod; bash ../scripts/init-stack.sh infra
#   tofu apply -var-file=envs/prod.tfvars
# Credentials and otc_project_name come from TF_VAR_* environment variables.
# =============================================================================
environment                   = "prod"
name_prefix                   = "tcloud-prod"
region                        = "eu-de"
availability_zones            = ["eu-de-01", "eu-de-02", "eu-de-03"]
reuse_existing_cce_agency     = true # cce_admin_trust already exists in the account
reuse_existing_evs_kms_agency = true # EVSAccessKMS already exists in the account

tags = {
  managed_by = "opentofu"
  project    = "tcloud-cce-reference"
}

# --- Network ---
vpc_cidr          = "10.250.0.0/16"
subnet_cidr       = "10.250.0.0/24"
service_cidr      = "10.247.0.0/16"
container_cidr    = "172.16.0.0/16"
nat_spec          = "1"
nat_eip_bandwidth = 100
bastion_cidrs     = []
nodeport_cidrs    = []

# --- Cluster ---
cluster_version          = "v1.35"
cluster_flavor           = "cce.s2.small"
container_network_type   = "overlay_l2"
high_availability        = true
kube_proxy_mode          = "ipvs"
bind_api_eip             = true # CI runners (workloads job) need the public API; restrict via api_access_trustlist
api_access_trustlist     = []
master_volume_encryption = true
delete_all_storage       = false
delete_all_network       = false

# --- Nodes ---
ssh_public_key         = "" # empty: RSA key pair is generated (output ssh_private_key_pem)
node_os                = "HCE OS 2.0"
node_runtime           = "containerd"
node_root_volume_type  = "SSD"
node_data_volume_type  = "SSD"
node_volume_encryption = true

node_pools = {
  workers = {
    flavor      = "s3.xlarge.2"
    count       = 3
    autoscaling = true
    min_count   = 3
    max_count   = 6
  }
}

# --- Addons ---
create_metrics_server = true
create_ingress        = false
ingress_eip_bandwidth = 100
create_lts            = true
lts_ttl_days          = 30

# --- DNS ---
# Placeholder zone: set a real, delegated zone and create_dns = true to let
# this stack manage it (wildcard record for the ingress ELB).
create_dns    = false
dns_zone_name = "tcloud.example.invalid."
dns_zone_type = "public"

# --- Audit / logging ---
# CTS: one system tracker per project (the project has none yet); traces to OBS (KMS) and LTS.
create_cts_tracker   = true
cts_retention_days   = 365
cts_lts_enabled      = true
vpc_flow_log_enabled = false # opt-in: flow log of the cluster VPC -> LTS

# --- OpenBao / workload identity ---
openbao_mode             = "disabled"
create_openbao_unseal    = false
create_workload_identity = false
