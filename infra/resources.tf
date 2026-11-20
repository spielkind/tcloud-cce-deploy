# =============================================================================
# Current Project
# =============================================================================
data "opentelekomcloud_identity_project_v3" "current" {
  name = var.otc_project_name
}

# --- Network ---
module "vpc" {
  source = "./modules/vpc"

  name_prefix     = var.name_prefix
  vpc_cidr        = var.vpc_cidr
  subnet_cidr     = var.subnet_cidr
  eni_subnet_cidr = var.eni_subnet_cidr
  vpc_dns_list    = var.vpc_dns_list
  tags            = var.tags
}

# --- Security Group ---
module "security_group" {
  source = "./modules/security-group"

  name_prefix   = var.name_prefix
  vpc_cidr      = var.vpc_cidr
  bastion_cidrs = var.bastion_cidrs
}

# --- SSH Key Pair ---
resource "opentelekomcloud_compute_keypair_v2" "this" {
  name       = "${var.name_prefix}-keypair"
  public_key = var.ssh_public_key
}

# --- IAM Agency (CCE authorization) ---
module "iam" {
  source                    = "./modules/iam"
  project_name              = var.otc_project_name
  reuse_existing_cce_agency = var.reuse_existing_cce_agency
}

# --- CCE Cluster ---
module "cce" {
  source = "./modules/cce"

  name_prefix            = var.name_prefix
  cluster_flavor         = var.cluster_flavor
  cluster_type           = var.cluster_type
  cluster_version        = var.cluster_version
  high_availability      = var.high_availability
  kube_proxy_mode        = var.kube_proxy_mode
  container_network_type = var.container_network_type
  vpc_id                 = module.vpc.vpc_id
  subnet_id              = module.vpc.subnet_network_id
  security_group_id      = module.security_group.security_group_id

  # ENI/Yangtse (only effective when container_network_type = "eni")
  eni_subnet_id   = module.vpc.eni_subnet_id != "" ? module.vpc.eni_subnet_id : module.vpc.subnet_v2_id
  eni_subnet_cidr = module.vpc.eni_subnet_cidr

  bind_eip = var.bind_api_eip
  tags     = var.tags

  depends_on = [module.iam]
}

# --- Node Pool ---
module "node_pool" {
  source = "./modules/node-pool"

  name_prefix         = var.name_prefix
  cluster_id          = module.cce.cluster_id
  node_flavor         = var.node_flavor
  node_os             = var.node_os
  node_count          = var.node_count
  key_pair            = opentelekomcloud_compute_keypair_v2.this.name
  subnet_id           = module.vpc.subnet_network_id
  autoscaling_enabled = var.autoscaling_enabled
  tags                = var.tags
}

# --- Cluster Autoscaler (only with autoscaling_enabled) ---
module "autoscaler" {
  source = "./modules/autoscaler"

  create_autoscaler  = var.autoscaling_enabled
  cluster_id         = module.cce.cluster_id
  project_id         = data.opentelekomcloud_identity_project_v3.current.id
  autoscaler_version = var.autoscaler_version
  region             = var.region

  depends_on = [module.node_pool]
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
  tags        = var.tags
}

# --- Ingress Controller (nginx) ---
module "ingress" {
  source = "./modules/ingress"

  cluster_id                   = module.cce.cluster_id
  vpc_id                       = module.vpc.vpc_id
  subnet_id                    = module.vpc.subnet_v2_id
  name_prefix                  = var.name_prefix
  create_ingress               = var.create_ingress
  nginx_ingress_version        = var.nginx_ingress_version
  nginx_ingress_controller_tag = var.nginx_ingress_controller_tag
  zone_id                      = module.dns.zone_id
  zone_name                    = var.dns_zone_name
  create_dns_record            = var.create_dns
  tags                         = var.tags

  depends_on = [module.node_pool]
}
# --- NAT Gateway (internet access for nodes) ---
module "nat" {
  source = "./modules/nat"

  name_prefix     = var.name_prefix
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.subnet_id
  eni_subnet_id   = module.vpc.eni_subnet_network_id
  create_eni_snat = var.eni_subnet_cidr != ""
  tags            = var.tags
}
# --- Log Agent (CCE log collection tool) ---
module "log_agent" {
  source = "./modules/log-agent"

  cluster_id           = module.cce.cluster_id
  cluster_name         = module.cce.cluster_name
  create_log_agent     = var.create_lts
  log_agent_version    = var.log_agent_version
  lts_group_id         = module.lts.log_group_id
  lts_stdout_stream_id = module.lts.stdout_stream_id
  lts_event_stream_id  = module.lts.event_stream_id

  depends_on = [module.node_pool]
}

# --- LTS Streams (attach to log-agent auto-created group) ---
module "lts" {
  source = "./modules/lts"

  cluster_id         = module.cce.cluster_id
  create_lts_streams = var.create_lts
  tags               = var.tags

  depends_on = [module.node_pool]
}

# =============================================================================
# SWR (Software Repository for Container)
# =============================================================================
module "swr" {
  source       = "./modules/swr"
  organization = var.name_prefix
}

# =============================================================================
# OpenBao Auto-Unseal (KMS + OBS + FunctionGraph)
# =============================================================================
module "openbao_unseal" {
  source = "./modules/openbao-unseal"

  name_prefix           = var.name_prefix
  create_openbao_unseal = var.create_openbao_unseal
  project_name          = var.otc_project_name
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.subnet_network_id
  enable_vpc_access     = true
  tags                  = var.tags
}

# =============================================================================
# Fetch JWKS from CCE cluster for workload identity
# =============================================================================
data "external" "jwks" {
  count = var.create_workload_identity ? 1 : 0
  program = ["bash", "-c", <<-EOF
    KUBECONFIG=$(mktemp)
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
    JWKS=$(kubectl get --raw /openid/v1/jwks --kubeconfig "$KUBECONFIG" 2>/dev/null)
    rm -f "$KUBECONFIG"
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
  create_workload_identity = var.create_workload_identity
  signing_key              = var.create_workload_identity ? data.external.jwks[0].result.jwks : ""
  project_id               = data.opentelekomcloud_identity_project_v3.current.id
  workloads = var.create_workload_identity ? [
    for w in [module.openbao_unseal.workload] : w if w != null
  ] : []
  tags = var.tags
}
