# --- Credentials (env vars only!) ---
variable "otc_access_key" {
  description = "OTC Access Key (AK)"
  type        = string
  sensitive   = true
}

variable "otc_secret_key" {
  description = "OTC Secret Key (SK)"
  type        = string
  sensitive   = true
}

variable "otc_domain_name" {
  description = "OTC Domain Name (Console → My Credentials)"
  type        = string
}

variable "otc_project_name" {
  description = "OTC project name (TF_VAR_otc_project_name, in CI from GitHub variable OTC_PROJECT_NAME)"
  type        = string
}

variable "reuse_existing_cce_agency" {
  description = "Use an existing cce_admin_trust agency without managing it"
  type        = bool
  default     = false
}

variable "reuse_existing_evs_kms_agency" {
  description = "Use an existing EVSAccessKMS agency without managing it (only relevant with node_volume_encryption)"
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "Availability zones for HA masters and general-purpose worker placement options"
  type        = list(string)
  default     = ["eu-de-01", "eu-de-02", "eu-de-03"]
  validation {
    condition     = length(var.availability_zones) > 0
    error_message = "At least one availability zone must be configured."
  }
}

variable "region" {
  description = "OTC Region"
  type        = string
  default     = "eu-de"
}

# --- General ---
variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "tcloud"
}

variable "tags" {
  description = "Default tags for all resources (environment = var.environment is merged in automatically)"
  type        = map(string)
  default = {
    managed_by = "opentofu"
    project    = "tcloud-cce-reference"
  }
}

# --- Network ---
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.248.0.0/16"
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "subnet_cidr" {
  description = "Subnet CIDR for nodes (must be within vpc_cidr; empty = <vpc_cidr>/24 at offset 1)"
  type        = string
  default     = ""
  validation {
    condition = var.subnet_cidr == "" || try(
      tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrsubnet("${cidrhost(var.subnet_cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0, 0) == cidrsubnet(var.vpc_cidr, 0, 0),
      false
    )
    error_message = "subnet_cidr must be a valid CIDR inside vpc_cidr."
  }
}

variable "eni_subnet_cidr" {
  description = "Separate subnet CIDR for ENI/pod IPs (Turbo/Yangtse only, must be within vpc_cidr). Empty = share node subnet."
  type        = string
  default     = ""
  validation {
    condition = var.eni_subnet_cidr == "" || try(
      tonumber(split("/", var.eni_subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrsubnet("${cidrhost(var.eni_subnet_cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0, 0) == cidrsubnet(var.vpc_cidr, 0, 0),
      false
    )
    error_message = "eni_subnet_cidr must be a valid CIDR inside vpc_cidr."
  }
}

variable "container_cidr" {
  description = "Virtual pod CIDR for overlay_l2/vpc-router clusters (ignored for eni; must not overlap vpc_cidr). Changing it recreates the cluster."
  type        = string
  default     = "172.16.0.0/16"
  validation {
    condition     = can(cidrhost(var.container_cidr, 0))
    error_message = "container_cidr must be a valid IPv4 CIDR."
  }
}

variable "service_cidr" {
  description = "Kubernetes service CIDR (kubernetes_svc_ip_range). Changing it recreates the cluster."
  type        = string
  default     = "10.247.0.0/16"
  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid IPv4 CIDR."
  }
}

variable "vpc_dns_list" {
  description = "DNS servers to inject into VPC"
  type        = list(string)
  default     = ["100.125.4.25", "100.125.129.199"] # Default OTC public EU-DE DNS
}

variable "bastion_cidrs" {
  description = "CIDRs allowed for SSH to worker nodes (empty = no SSH)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.bastion_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "bastion_cidrs must contain valid, restricted CIDRs (no /0)."
  }
}

variable "nodeport_cidrs" {
  description = "CIDRs allowed to reach the NodePort range on workers. Empty = vpc_cidr, or 0.0.0.0/0 when create_ingress is set on a non-eni cluster (shared ELB keeps client IPs)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.nodeport_cidrs : can(cidrhost(c, 0))])
    error_message = "nodeport_cidrs must contain valid CIDRs."
  }
}

variable "expose_node_http_ports" {
  description = "Open TCP 80/443 on worker nodes to 0.0.0.0/0. Not needed for the ELB-based ingress; only for hostNetwork/hostPort workloads."
  type        = bool
  default     = false
}

variable "nat_spec" {
  description = "NAT gateway size: 1 (small), 2 (medium), 3 (large), 4 (extra-large)"
  type        = string
  default     = "1"
  validation {
    condition     = contains(["1", "2", "3", "4"], var.nat_spec)
    error_message = "nat_spec must be one of \"1\", \"2\", \"3\", \"4\"."
  }
}

variable "nat_eip_bandwidth" {
  description = "NAT gateway EIP bandwidth in Mbit/s"
  type        = number
  default     = 100
}

# --- CCE ---
variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "v1.35"
}

variable "cluster_flavor" {
  description = "CCE cluster flavor (s1=single master, s2=HA)"
  type        = string
  default     = "cce.s1.small"
}

variable "cluster_type" {
  description = "CCE cluster type: VirtualMachine or BareMetal"
  type        = string
  default     = "VirtualMachine"
  validation {
    condition     = contains(["VirtualMachine", "BareMetal"], var.cluster_type)
    error_message = "Must be VirtualMachine or BareMetal."
  }
}

variable "container_network_type" {
  description = "CCE container network mode: overlay_l2 (Canal/Standard), vpc-router (VPC/Standard), or eni (Cloud Native 2.0/Turbo)"
  type        = string
  default     = "overlay_l2"
  validation {
    condition     = contains(["overlay_l2", "vpc-router", "eni"], var.container_network_type)
    error_message = "Must be overlay_l2, vpc-router, or eni."
  }
}

variable "api_access_trustlist" {
  description = "CIDRs allowed to reach the CCE API (empty = unrestricted)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.api_access_trustlist : can(cidrhost(c, 0))])
    error_message = "api_access_trustlist must contain valid CIDRs."
  }
}

variable "component_configurations" {
  description = "CCE cluster component configurations (component => { key = value })"
  type        = map(map(string))
  default = {
    "kube-apiserver" = { "support-overload" = "true" }
  }
}

variable "master_volume_encryption" {
  description = "Encrypt CCE master node disks (enable_volume_encryption). Changing it recreates the cluster."
  type        = bool
  default     = false
}

variable "node_volume_encryption" {
  description = "Encrypt worker root/data volumes with a dedicated, yearly rotated KMS key (creates EVSAccessKMS agency unless reused)"
  type        = bool
  default     = true
}

variable "delete_all_storage" {
  description = "Delete cluster-created EVS/SFS/OBS storage on cluster destroy (also force-destroys the CTS audit bucket)"
  type        = bool
  default     = true
}

variable "delete_all_network" {
  description = "Delete cluster-created ELBs/ENIs on cluster destroy"
  type        = bool
  default     = true
}

variable "cluster_create_timeout" {
  description = "Timeout for CCE cluster creation"
  type        = string
  default     = "60m"
}

variable "cluster_delete_timeout" {
  description = "Timeout for CCE cluster deletion"
  type        = string
  default     = "60m"
}

variable "high_availability" {
  description = "HA cluster (3 masters across AZs) or single master"
  type        = bool
  default     = false
}

variable "kube_proxy_mode" {
  description = "kube-proxy mode: iptables or ipvs"
  type        = string
  default     = "iptables"
  validation {
    condition     = contains(["iptables", "ipvs"], var.kube_proxy_mode)
    error_message = "Must be iptables or ipvs."
  }
}

variable "node_pools" {
  description = <<-EOT
    Worker node pools keyed by name suffix (pool name = <name_prefix>-<key>).
    Optional attributes fall back to sensible defaults; gpu = true marks an NVIDIA
    GPU pool (GPU addon, NVIDIA label/taint defaults, scale-from-zero friendly).
  EOT
  type = map(object({
    flavor              = string
    count               = optional(number) # initial nodes; default 1, or min_count with autoscaling
    autoscaling         = optional(bool, false)
    min_count           = optional(number)           # default 1 (0 for gpu pools)
    max_count           = optional(number)           # default 2 x count
    az                  = optional(string, "random") # "random" or an AZ such as "eu-de-01"
    os                  = optional(string)           # default: node_os
    runtime             = optional(string)           # default: node_runtime
    root_volume_size    = optional(number, 50)
    root_volume_type    = optional(string) # default: node_root_volume_type
    data_volume_size    = optional(number, 100)
    data_volume_type    = optional(string)      # default: node_data_volume_type
    priority            = optional(number)      # autoscaler priority; default 1 (0 for gpu pools)
    scale_down_cooldown = optional(number, 15)  # minutes
    gpu                 = optional(bool, false) # NVIDIA GPU flavor: enables the GPU addon
    labels              = optional(map(string)) # default {} ({accelerator = "nvidia"} for gpu pools)
    taints = optional(list(object({             # default [] (nvidia.com/gpu=present:NoSchedule for gpu pools)
      key    = string
      value  = optional(string, "")
      effect = string
    })))
  }))
  default = {
    workers = { flavor = "s3.xlarge.2", count = 3 }
  }

  validation {
    condition     = alltrue([for k, _ in var.node_pools : can(regex("^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$", k))])
    error_message = "node_pools keys must be 1-20 lowercase letters, digits or hyphens."
  }
  validation {
    condition     = anytrue([for p in var.node_pools : !p.gpu])
    error_message = "node_pools needs at least one non-GPU pool for system components."
  }
  validation {
    # CCE Turbo (eni) needs network-enhanced CPU flavors and supports only g7/pi5e/p5e GPU flavors.
    condition = alltrue([
      for p in var.node_pools : p.gpu
      ? can(regex(var.container_network_type == "eni" ? "^(g7|pi5e|p5e)\\." : "^(g6|g7|p2s|p2v|p3|p5e|p5s|pi2|pi5e)\\.", p.flavor))
      : !(var.container_network_type == "eni" && can(regex("^(s[1-3]|c[34]|m[34])\\.", p.flavor)))
    ])
    error_message = "Invalid flavor: CCE Turbo (eni) needs CPU flavors like s7n/c7n/m7n/c3n and GPU flavors g7, pi5e or p5e; gpu = true requires a GPU flavor."
  }
  validation {
    condition     = alltrue([for p in var.node_pools : p.az == "random" || can(regex("^[a-z]{2}-[a-z0-9]+-[0-9]{2}$", p.az))])
    error_message = "node_pools[*].az must be \"random\" or an AZ name such as eu-de-01."
  }
  validation {
    condition = alltrue([for p in var.node_pools :
      coalesce(p.count, 0) >= 0 && coalesce(p.min_count, 0) >= 0 &&
      (p.min_count == null || p.max_count == null || p.min_count <= p.max_count)
    ])
    error_message = "node_pools counts must be non-negative and min_count <= max_count."
  }
  validation {
    condition = alltrue([for p in var.node_pools :
      p.root_volume_size >= 40 && p.root_volume_size <= 1024 && p.data_volume_size >= 100 && p.data_volume_size <= 32768
    ])
    error_message = "root_volume_size must be 40-1024 GB and data_volume_size 100-32768 GB."
  }
  validation {
    condition = alltrue(flatten([for p in var.node_pools : [
      for t in coalesce(p.taints, []) : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
    ]]))
    error_message = "Taint effect must be NoSchedule, PreferNoSchedule or NoExecute."
  }
}

variable "node_runtime" {
  description = "Container runtime for worker nodes"
  type        = string
  default     = "containerd"
  validation {
    condition     = contains(["containerd", "docker"], var.node_runtime)
    error_message = "node_runtime must be containerd or docker."
  }
}

variable "node_root_volume_type" {
  description = "Root volume type for workers"
  type        = string
  default     = "SSD"
  validation {
    condition     = contains(["SATA", "SAS", "SSD", "GPSSD", "ESSD"], var.node_root_volume_type)
    error_message = "node_root_volume_type must be SATA, SAS, SSD, GPSSD or ESSD."
  }
}

variable "node_data_volume_type" {
  description = "Data volume type for workers"
  type        = string
  default     = "SSD"
  validation {
    condition     = contains(["SATA", "SAS", "SSD", "GPSSD", "ESSD"], var.node_data_volume_type)
    error_message = "node_data_volume_type must be SATA, SAS, SSD, GPSSD or ESSD."
  }
}

variable "node_os" {
  description = "Worker node OS (HCE OS 2.0 is recommended for v1.35+)"
  type        = string
  default     = "HCE OS 2.0"
}

variable "ssh_public_key" {
  description = "Optional SSH public key for workers; empty generates an RSA 4096 key pair (output ssh_private_key_pem). SSH still needs bastion_cidrs."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment name (no default: always pass -var-file=envs/<env>.tfvars matching the backend file)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "gpu_addon_version" {
  description = "CCE AI Suite (NVIDIA GPU) addon version (template gpu-beta) or \"latest\""
  type        = string
  default     = "2.15.6"
}

variable "gpu_xgpu" {
  description = "GPU slicing: enable CCE xGPU in the GPU addon and install the Volcano scheduler (pods share one GPU with hard VRAM/compute limits)"
  type        = bool
  default     = false
}

variable "volcano_version" {
  description = "Volcano scheduler addon version or \"latest\" (installed only with gpu_xgpu = true)"
  type        = string
  default     = "1.22.5"
}

variable "nvidia_driver_url" {
  description = "NVIDIA Tesla driver .run URL installed on GPU nodes"
  type        = string
  default     = "https://us.download.nvidia.com/tesla/580.196.07/NVIDIA-Linux-x86_64-580.196.07.run"
}

variable "autoscaler_version" {
  description = "CCE autoscaler addon version (must match the cluster's minor version) or \"latest\""
  type        = string
  default     = "1.35.8"
}

# --- DNS ---
variable "create_dns" {
  description = "Create a private DNS zone"
  type        = bool
  default     = false
}

variable "dns_zone_name" {
  description = "DNS zone name (trailing dot required)"
  type        = string
  default     = "cluster.internal."
}

# --- Ingress ---
variable "create_ingress" {
  description = "Install nginx-ingress CCE addon"
  type        = bool
  default     = false
}

variable "dns_zone_type" {
  description = "DNS zone type: public or private"
  type        = string
  default     = "public"
}

variable "bind_api_eip" {
  description = "Bind public EIP to CCE API for external kubectl access"
  type        = bool
  default     = false
}

variable "api_eip_bandwidth" {
  description = "Public CCE API EIP bandwidth in Mbit/s"
  type        = number
  default     = 10
}

variable "create_lts" {
  description = "Create LTS log group and streams and install the log-agent addon"
  type        = bool
  default     = false
}

variable "lts_ttl_days" {
  description = "Retention of the cluster LTS log group in days"
  type        = number
  default     = 7
  validation {
    condition     = var.lts_ttl_days >= 1 && var.lts_ttl_days <= 365
    error_message = "lts_ttl_days must be between 1 and 365."
  }
}

variable "ingress_eip_bandwidth" {
  description = "Ingress ELB EIP bandwidth in Mbit/s"
  type        = number
  default     = 100
}

variable "ingress_preserve_client_ip" {
  description = "Set externalTrafficPolicy Local on the nginx-ingress Service to preserve client source IPs (template default); false = Cluster"
  type        = bool
  default     = true
}

variable "create_metrics_server" {
  description = "Install the metrics-server CCE addon (HPA, kubectl top)"
  type        = bool
  default     = true
}

variable "metrics_server_version" {
  description = "metrics-server addon version or \"latest\""
  type        = string
  default     = "1.3.132"
}

# --- Audit (CTS) ---
variable "create_cts_tracker" {
  description = "Create the CTS system tracker with a KMS-encrypted OBS audit bucket (fails if the project already has one)"
  type        = bool
  default     = false
}

variable "cts_retention_days" {
  description = "Days to keep CTS audit files in OBS"
  type        = number
  default     = 365
}

variable "cts_lts_enabled" {
  description = "Also ship CTS traces to LTS"
  type        = bool
  default     = false
}

variable "vpc_flow_log_enabled" {
  description = "Ship VPC flow logs of the cluster VPC to a dedicated stream in the cluster LTS group (requires create_lts)"
  type        = bool
  default     = false
}

variable "vpc_flow_log_traffic" {
  description = "Traffic recorded by the VPC flow log: all, accept or reject"
  type        = string
  default     = "reject"
  validation {
    condition     = contains(["all", "accept", "reject"], var.vpc_flow_log_traffic)
    error_message = "vpc_flow_log_traffic must be all, accept or reject."
  }
}

# --- Addon Versions ---
variable "log_agent_version" {
  description = "CCE log-agent addon version or \"latest\""
  type        = string
  default     = "1.7.10"
}

variable "nginx_ingress_version" {
  description = "CCE nginx-ingress addon version or \"latest\" (then nginx_ingress_controller_tag must match)"
  type        = string
  default     = "6.0.24"
}

variable "nginx_ingress_controller_tag" {
  description = "Controller image tag v<controller>_<addon>; must end with _<resolved addon version> (see addontemplates API spec.versions[].input.basic.tag)"
  type        = string
  default     = "v1.14.5_6.0.24"
}

# --- OpenBao Auto-Unseal ---
variable "create_openbao_unseal" {
  description = "Create KMS key, OBS bucket and FunctionGraph function for OpenBao auto-unseal"
  type        = bool
  default     = false
}

# --- Workload Identity (OIDC) ---
variable "create_workload_identity" {
  description = "Create IAM OIDC identity provider for CCE workload identity (requires bind_api_eip)"
  type        = bool
  default     = false

  validation {
    condition     = !var.create_workload_identity || var.bind_api_eip
    error_message = "create_workload_identity requires bind_api_eip = true: the cluster's JWKS is fetched via the public API endpoint."
  }
}

variable "openbao_mode" {
  description = "OpenBao placement: disabled, cce (Helm in workloads), or vm (dedicated ECS Raft cluster)"
  type        = string
  default     = "cce"
  validation {
    condition     = contains(["disabled", "cce", "vm"], var.openbao_mode)
    error_message = "openbao_mode must be disabled, cce, or vm."
  }
}

variable "openbao_vm" {
  description = "Configuration for the optional dedicated-VM OpenBao implementation"
  type = object({
    subnet_cidr              = string
    vpc_cidr                 = string
    availability_zones       = list(string)
    ecs_flavor               = string
    image_name               = string
    evs_size                 = number
    version                  = string
    fqdn                     = string
    public_dns_zone_id       = string
    enable_public_dns_record = bool
    api_allowed_cidrs        = list(string)
    tls_cert_pem             = string
    tls_key_pem              = string
    tls_ca_cert_pem          = string
    tls_fqdn                 = string
    enable_auto_unseal       = bool
    kms_admin_role_name      = string
    enable_bastion           = bool
    bastion_allowed_cidrs    = list(string)
    enable_letsencrypt       = bool
    letsencrypt_email        = string
    enable_lts_logging       = bool
    lts_ttl_days             = number
    elb_eip_bandwidth        = number
    nat_eip_bandwidth        = number
    bastion_eip_bandwidth    = number
  })
  default = {
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
    enable_bastion           = true # required for openbao_mode = vm (bao-init.sh runs on the bastion)
    bastion_allowed_cidrs    = []
    enable_letsencrypt       = false
    letsencrypt_email        = ""
    enable_lts_logging       = false
    lts_ttl_days             = 30
    elb_eip_bandwidth        = 100
    nat_eip_bandwidth        = 100
    bastion_eip_bandwidth    = 10
  }
  validation {
    condition     = var.openbao_mode != "vm" || (length(var.openbao_vm.availability_zones) >= 1 && length(var.openbao_vm.api_allowed_cidrs) > 0 && (var.openbao_vm.enable_letsencrypt ? (var.openbao_vm.fqdn != "" && var.openbao_vm.letsencrypt_email != "" && var.openbao_vm.public_dns_zone_id != "" && var.openbao_vm.enable_bastion && length(var.openbao_vm.bastion_allowed_cidrs) > 0) : (var.openbao_vm.tls_cert_pem != "" && var.openbao_vm.tls_key_pem != "" && var.openbao_vm.tls_ca_cert_pem != "" && var.openbao_vm.tls_fqdn != "")))
    error_message = "For VM mode configure AZs and restricted API client CIDRs, plus either Let's Encrypt (fqdn/email/public DNS zone ID and bastion with restricted SSH CIDRs) or all BYO TLS certificate fields."
  }
  validation {
    condition = alltrue([
      for c in concat(var.openbao_vm.api_allowed_cidrs, var.openbao_vm.bastion_allowed_cidrs) :
      can(cidrhost(c, 0)) && !endswith(c, "/0")
    ])
    error_message = "openbao_vm.api_allowed_cidrs and bastion_allowed_cidrs must be valid, restricted CIDRs (no /0)."
  }
  validation {
    # Pods and admins reach OpenBao via https://<fqdn>; with Let's Encrypt the
    # zone is ours, so publish the record. BYO TLS needs external DNS instead.
    condition     = var.openbao_mode != "vm" || !var.openbao_vm.enable_letsencrypt || var.openbao_vm.enable_public_dns_record
    error_message = "openbao_mode = \"vm\" with Let's Encrypt requires openbao_vm.enable_public_dns_record = true (the CCE cluster resolves OpenBao via public DNS)."
  }
  validation {
    # Initialization (bao-init.sh) only exists on the bastion.
    condition     = var.openbao_mode != "vm" || var.openbao_vm.enable_bastion
    error_message = "openbao_mode = \"vm\" requires openbao_vm.enable_bastion = true (OpenBao is initialized from the bastion)."
  }
}
