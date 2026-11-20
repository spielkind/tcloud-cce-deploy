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

variable "region" {
  description = "OTC Region"
  type        = string
  default     = "eu-de"
}

# --- General ---
variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "test"
}

variable "tags" {
  description = "Default tags for all resources"
  type        = map(string)
  default = {
    managed_by = "terraform"
    project    = "test"
  }
}

# --- Network ---
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.248.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR for nodes (must be within vpc_cidr)"
  type        = string
  default     = ""
}

variable "eni_subnet_cidr" {
  description = "Separate subnet CIDR for ENI/pod IPs (Yangtse only). Creates a dedicated pod subnet. Empty = share node subnet."
  type        = string
  default     = ""
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

variable "node_flavor" {
  description = "Worker node ECS flavor"
  type        = string
  default     = "s3.xlarge.2"
}

variable "node_os" {
  description = "Worker node OS (HCE OS 2.0 is recommended for v1.35+)"
  type        = string
  default     = "HCE OS 2.0"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "ssh_public_key" {
  description = "SSH public key (ssh-rsa AAAA...)"
  type        = string
}

variable "autoscaling_enabled" {
  description = "Enable node pool autoscaling (installs the CCE autoscaler addon)"
  type        = bool
  default     = false
}

variable "autoscaler_version" {
  description = "CCE autoscaler addon version (must match the cluster's minor version)"
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

variable "create_lts" {
  description = "Create LTS log group and streams"
  type        = bool
  default     = false
}


# --- Addon Versions ---
variable "log_agent_version" {
  description = "CCE log-agent addon version"
  type        = string
  default     = "1.7.10"
}

variable "nginx_ingress_version" {
  description = "CCE nginx-ingress addon version"
  type        = string
  default     = "6.0.24"
}

variable "nginx_ingress_controller_tag" {
  description = "Full image tag (v<controller>_<addon>). Check addontemplates API for mapping."
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

