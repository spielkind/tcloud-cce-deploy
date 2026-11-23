# =============================================================================
# Current Project
# =============================================================================
data "opentelekomcloud_identity_project_v3" "current" {
  name = var.otc_project_name
}

locals {
  tags = merge(var.tags, { environment = var.environment })
}

# --- Network ---
module "vpc" {
  source = "./modules/vpc"

  name_prefix     = var.name_prefix
  vpc_cidr        = var.vpc_cidr
  subnet_cidr     = var.subnet_cidr
  eni_subnet_cidr = var.eni_subnet_cidr
  vpc_dns_list    = var.vpc_dns_list
  tags            = local.tags
}

# --- CCE Cluster ---
module "cce" {
  source = "./modules/cce"

  name_prefix                   = var.name_prefix
  tags                          = local.tags
  project_name                  = var.otc_project_name
  project_id                    = data.opentelekomcloud_identity_project_v3.current.id
  region                        = var.region
  reuse_existing_cce_agency     = var.reuse_existing_cce_agency
  reuse_existing_evs_kms_agency = var.reuse_existing_evs_kms_agency

  # Cluster
  cluster_flavor           = var.cluster_flavor
  cluster_type             = var.cluster_type
  cluster_version          = var.cluster_version
  high_availability        = var.high_availability
  availability_zones       = var.availability_zones
  kube_proxy_mode          = var.kube_proxy_mode
  container_network_type   = var.container_network_type
  container_cidr           = var.container_cidr
  service_cidr             = var.service_cidr
  api_access_trustlist     = var.api_access_trustlist
  component_configurations = var.component_configurations
  master_volume_encryption = var.master_volume_encryption
  delete_all_storage       = var.delete_all_storage
  delete_all_network       = var.delete_all_network
  cluster_create_timeout   = var.cluster_create_timeout
  cluster_delete_timeout   = var.cluster_delete_timeout
  bind_eip                 = var.bind_api_eip
  api_eip_bandwidth        = var.api_eip_bandwidth

  # Network
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_id         = module.vpc.subnet_network_id
  subnet_neutron_id = module.vpc.subnet_v2_id
  # ENI/Yangtse (only effective when container_network_type = "eni")
  eni_subnet_id   = module.vpc.eni_subnet_id != "" ? module.vpc.eni_subnet_id : module.vpc.subnet_v2_id
  eni_subnet_cidr = module.vpc.eni_subnet_cidr

  # Worker access
  bastion_cidrs          = var.bastion_cidrs
  nodeport_cidrs         = var.nodeport_cidrs
  expose_node_http_ports = var.expose_node_http_ports
  ssh_public_key         = var.ssh_public_key

  # Node pools
  node_pools             = var.node_pools
  node_os                = var.node_os
  node_runtime           = var.node_runtime
  node_root_volume_type  = var.node_root_volume_type
  node_data_volume_type  = var.node_data_volume_type
  node_volume_encryption = var.node_volume_encryption

  # Addons
  autoscaler_version           = var.autoscaler_version
  gpu_addon_version            = var.gpu_addon_version
  nvidia_driver_url            = var.nvidia_driver_url
  create_metrics_server        = var.create_metrics_server
  metrics_server_version       = var.metrics_server_version
  create_ingress               = var.create_ingress
  nginx_ingress_version        = var.nginx_ingress_version
  nginx_ingress_controller_tag = var.nginx_ingress_controller_tag
  ingress_eip_bandwidth        = var.ingress_eip_bandwidth
  ingress_preserve_client_ip   = var.ingress_preserve_client_ip
  dns_zone_id                  = module.dns.zone_id
  dns_zone_name                = var.dns_zone_name
  create_dns_record            = var.create_dns
  create_lts                   = var.create_lts
  lts_ttl_days                 = var.lts_ttl_days
  log_agent_version            = var.log_agent_version
}

# --- DNS (optional) ---
module "dns" {
  source = "./modules/dns"

  name_prefix = var.name_prefix
  vpc_id      = module.vpc.vpc_id
  create_dns  = var.create_dns
  zone_name   = var.dns_zone_name
  zone_type   = var.dns_zone_type
  region      = var.region
  tags        = local.tags
}

# --- NAT Gateway (internet access for nodes) ---
module "nat" {
  source = "./modules/nat"

  name_prefix     = var.name_prefix
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.subnet_id
  eni_subnet_id   = module.vpc.eni_subnet_network_id
  create_eni_snat = var.eni_subnet_cidr != ""
  nat_spec        = var.nat_spec
  eip_bandwidth   = var.nat_eip_bandwidth
  tags            = local.tags
}
# =============================================================================
# SWR (Software Repository for Container)
# =============================================================================
module "swr" {
  source       = "./modules/swr"
  organization = var.name_prefix
  region       = var.region
}

# =============================================================================
# OpenBao Auto-Unseal (KMS + OBS + FunctionGraph)
# =============================================================================
module "openbao_unseal" {
  source = "./modules/openbao-unseal"

  name_prefix           = var.name_prefix
  create_openbao_unseal = var.create_openbao_unseal && var.openbao_mode == "cce"
  project_name          = var.otc_project_name
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.subnet_network_id
  enable_vpc_access     = true
  tags                  = local.tags
}

# Optional dedicated-VM OpenBao cluster.
module "openbao_vm" {
  count  = var.openbao_mode == "vm" ? 1 : 0
  source = "./modules/openbao"

  providers = {
    opentelekomcloud          = opentelekomcloud
    opentelekomcloud.regional = opentelekomcloud.regional
  }

  name_prefix              = var.name_prefix
  region                   = var.region
  otc_project_name         = var.otc_project_name
  vpc_cidr                 = var.openbao_vm.vpc_cidr
  subnet_cidr              = var.openbao_vm.subnet_cidr
  availability_zones       = var.openbao_vm.availability_zones
  ecs_flavor               = var.openbao_vm.ecs_flavor
  image_name               = var.openbao_vm.image_name
  evs_size                 = var.openbao_vm.evs_size
  ssh_public_key           = var.ssh_public_key
  openbao_version          = var.openbao_vm.version
  public_dns_record_name   = var.openbao_vm.fqdn
  public_dns_zone_id       = var.openbao_vm.public_dns_zone_id
  enable_public_dns_record = var.openbao_vm.enable_public_dns_record
  # The CCE NAT EIP is always allowed so pods (injector, apps) can reach the API.
  api_allowed_cidrs = var.openbao_vm.api_allowed_cidrs
  # The CCE NAT EIP is unknown at plan time, so it gets its own rule instead of
  # being merged into api_allowed_cidrs (that would make the rule count unknown).
  allow_cce_nat_cidr        = true
  cce_nat_cidr              = "${module.nat.nat_public_ip}/32"
  tls_cert_pem              = var.openbao_vm.tls_cert_pem
  tls_key_pem               = var.openbao_vm.tls_key_pem
  tls_ca_cert_pem           = var.openbao_vm.tls_ca_cert_pem
  tls_fqdn                  = var.openbao_vm.tls_fqdn
  enable_auto_unseal        = var.openbao_vm.enable_auto_unseal
  kms_admin_role_name       = var.openbao_vm.kms_admin_role_name
  enable_bastion            = var.openbao_vm.enable_bastion
  bastion_ssh_allowed_cidrs = var.openbao_vm.bastion_allowed_cidrs
  enable_letsencrypt        = var.openbao_vm.enable_letsencrypt
  letsencrypt_email         = var.openbao_vm.letsencrypt_email
  enable_lts_logging        = var.openbao_vm.enable_lts_logging
  lts_ttl_days              = var.openbao_vm.lts_ttl_days
  elb_eip_bandwidth         = var.openbao_vm.elb_eip_bandwidth
  nat_eip_bandwidth         = var.openbao_vm.nat_eip_bandwidth
  bastion_eip_bandwidth     = var.openbao_vm.bastion_eip_bandwidth
  tags                      = local.tags
}

# =============================================================================
# Fetch JWKS from CCE cluster for workload identity
# =============================================================================
data "external" "jwks" {
  count = var.create_workload_identity && var.openbao_mode == "cce" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    set -euo pipefail
    KUBECONFIG=$(mktemp)
    trap 'rm -f "$KUBECONFIG"' EXIT
    SERVER="https://${module.cce.cluster_api_public_ip}:5443"
    cat > "$KUBECONFIG" <<KCEOF
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: $SERVER
        certificate-authority-data: ${module.cce.cluster_ca_cert}
      name: cce
    users:
    - name: admin
      user:
        client-certificate-data: ${module.cce.client_cert}
        client-key-data: ${module.cce.client_key}
    contexts:
    - context:
        cluster: cce
        user: admin
      name: cce
    current-context: cce
    KCEOF
    # The public API endpoint may need a moment after cluster creation.
    JWKS=""
    for _ in $(seq 1 12); do
      JWKS=$(kubectl get --raw /openid/v1/jwks --kubeconfig "$KUBECONFIG" 2>/dev/null) && [ -n "$JWKS" ] && break
      sleep 10
    done
    if [ -z "$JWKS" ]; then
      echo "Could not read /openid/v1/jwks from $SERVER (API reachable? bind_api_eip and api_access_trustlist?)" >&2
      exit 1
    fi
    echo "{\"jwks\": $(echo "$JWKS" | jq -c '@json')}"
  EOF
  ]
}

# =============================================================================
# Workload Identity (OIDC for CCE pods)
# =============================================================================
module "workload_identity" {
  source = "./modules/workload-identity"

  name_prefix              = var.name_prefix
  create_workload_identity = var.create_workload_identity && var.openbao_mode == "cce"
  signing_key              = var.create_workload_identity && var.openbao_mode == "cce" ? data.external.jwks[0].result.jwks : ""
  project_id               = data.opentelekomcloud_identity_project_v3.current.id
  workloads = var.create_workload_identity && var.openbao_mode == "cce" ? [
    for w in [module.openbao_unseal.workload] : w if w != null
  ] : []
  tags = local.tags
}

# =============================================================================
# Cloud Trace Service (CTS) audit tracker (optional)
# A project has exactly one "system" tracker; enable only if none exists yet.
# OBS SSE-KMS requires a key from the region's base project, hence the
# regional provider for the key.
# =============================================================================
resource "random_id" "audit" {
  count       = var.create_cts_tracker ? 1 : 0
  byte_length = 4
}

resource "opentelekomcloud_kms_key_v1" "audit" {
  count    = var.create_cts_tracker ? 1 : 0
  provider = opentelekomcloud.regional

  key_alias       = "${var.name_prefix}-audit-${random_id.audit[0].hex}"
  key_description = "Encryption key for the CTS audit bucket"
  pending_days    = 7
  is_enabled      = true

  rotation_enabled  = true
  rotation_interval = 365

  tags = local.tags
}

resource "opentelekomcloud_obs_bucket" "audit" {
  count = var.create_cts_tracker ? 1 : 0

  bucket        = "${var.name_prefix}-audit-${random_id.audit[0].hex}"
  acl           = "private"
  versioning    = false
  force_destroy = var.delete_all_storage
  tags          = local.tags

  server_side_encryption {
    algorithm  = "kms"
    kms_key_id = opentelekomcloud_kms_key_v1.audit[0].id
  }

  lifecycle_rule {
    name    = "audit-retention"
    enabled = true
    expiration {
      days = var.cts_retention_days
    }
  }
}

resource "opentelekomcloud_cts_tracker_v3" "system" {
  count = var.create_cts_tracker ? 1 : 0

  status           = "enabled"
  bucket_name      = opentelekomcloud_obs_bucket.audit[0].bucket
  file_prefix_name = "cts-audit"
  is_lts_enabled   = var.cts_lts_enabled
  compress_type    = "gzip"
}
