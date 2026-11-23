# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "name_prefix" {
  description = "Prefix for all resource names. Changing it recreates the cluster."
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources"
  type        = map(string)
  default     = {}
}

variable "project_name" {
  description = "OTC project name (IAM agency scope)"
  type        = string
}

variable "project_id" {
  description = "OTC project ID (autoscaler tenant_id)"
  type        = string
}

variable "region" {
  description = "OTC region used for service endpoints and IAM role scopes"
  type        = string
}

variable "reuse_existing_cce_agency" {
  description = "Use an existing cce_admin_trust agency instead of creating it"
  type        = bool
  default     = false
}

variable "reuse_existing_evs_kms_agency" {
  description = "Use an existing EVSAccessKMS agency instead of creating it (only relevant with node_volume_encryption)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
variable "cluster_flavor" {
  description = "CCE cluster flavor, e.g. cce.s1.small or cce.s2.small"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "v1.35"
}

variable "cluster_type" {
  description = "VirtualMachine or BareMetal"
  type        = string
  default     = "VirtualMachine"
}

variable "high_availability" {
  description = "Distribute three masters across availability_zones"
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "Availability zones for masters and node placement"
  type        = list(string)
  default     = ["eu-de-01", "eu-de-02", "eu-de-03"]
}

variable "kube_proxy_mode" {
  description = "iptables or ipvs"
  type        = string
  default     = "iptables"
}

variable "container_network_type" {
  description = "overlay_l2, vpc-router or eni (CCE Turbo)"
  type        = string
  default     = "overlay_l2"
}

variable "container_cidr" {
  description = "Virtual pod CIDR for overlay_l2/vpc-router clusters (ignored in eni mode)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR (kubernetes_svc_ip_range)"
  type        = string
  default     = "10.247.0.0/16"
}

variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "subnet_id" { type = string }

variable "subnet_neutron_id" {
  description = "Neutron subnet ID of the node subnet (ELB VIP subnet)"
  type        = string
}

variable "eni_subnet_id" {
  description = "Neutron subnet ID for pod ENIs (eni mode only)"
  type        = string
  default     = ""
}

variable "eni_subnet_cidr" {
  description = "CIDR of the pod ENI subnet (eni mode only)"
  type        = string
  default     = ""
}

variable "bind_eip" {
  description = "Bind a public EIP to the CCE API"
  type        = bool
  default     = false
}

variable "api_eip_bandwidth" {
  description = "CCE API EIP bandwidth in Mbit/s"
  type        = number
  default     = 10
}

variable "api_access_trustlist" {
  description = "CIDRs allowed to reach the CCE API (empty = unrestricted)"
  type        = list(string)
  default     = []
}

variable "component_configurations" {
  description = "CCE component configurations, e.g. { \"kube-apiserver\" = { \"support-overload\" = \"true\" } }"
  type        = map(map(string))
  default     = {}
}

variable "master_volume_encryption" {
  description = "Encrypt master node system/data disks (enable_volume_encryption). Changing it recreates the cluster."
  type        = bool
  default     = false
}

variable "delete_all_storage" {
  description = "Delete EVS/SFS/OBS volumes created by the cluster when it is destroyed"
  type        = bool
  default     = true
}

variable "delete_all_network" {
  description = "Delete ELBs/ENIs created by the cluster when it is destroyed"
  type        = bool
  default     = true
}

variable "cluster_create_timeout" {
  description = "Timeout for cluster creation"
  type        = string
  default     = "60m"
}

variable "cluster_delete_timeout" {
  description = "Timeout for cluster deletion"
  type        = string
  default     = "60m"
}

# -----------------------------------------------------------------------------
# Worker access / security group
# -----------------------------------------------------------------------------
variable "bastion_cidrs" {
  description = "CIDRs allowed to SSH to worker nodes"
  type        = list(string)
  default     = []
}

variable "nodeport_cidrs" {
  description = "CIDRs allowed to reach the NodePort range. Empty = automatic (see security-group.tf)."
  type        = list(string)
  default     = []
}

variable "expose_node_http_ports" {
  description = "Open TCP 80/443 on worker nodes to 0.0.0.0/0 (only for hostNetwork/hostPort workloads)"
  type        = bool
  default     = false
}

variable "ssh_public_key" {
  description = "SSH public key for worker nodes; empty generates an RSA 4096 key pair"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Node pools
# -----------------------------------------------------------------------------
variable "node_pools" {
  description = "Node pools keyed by name suffix (<name_prefix>-<key>); see node-pools.tf"
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
}

variable "node_os" { type = string }

variable "node_runtime" {
  description = "Container runtime for worker nodes"
  type        = string
  default     = "containerd"
}

variable "node_root_volume_type" {
  description = "Root volume type"
  type        = string
  default     = "SSD"
}

variable "node_data_volume_type" {
  description = "Data volume type"
  type        = string
  default     = "SSD"
}

variable "node_volume_encryption" {
  description = "Encrypt worker root/data volumes with a dedicated KMS key"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Addons ("latest" resolves the newest template version for cluster_version)
# -----------------------------------------------------------------------------
variable "autoscaler_version" {
  type    = string
  default = "1.35.8"
}

variable "gpu_addon_version" {
  type    = string
  default = "2.15.6"
}

variable "gpu_xgpu" {
  type    = bool
  default = false
}

variable "volcano_version" {
  type    = string
  default = "1.22.5"
}

variable "nvidia_driver_url" { type = string }

variable "create_metrics_server" {
  type    = bool
  default = true
}

variable "metrics_server_version" {
  type    = string
  default = "1.3.132"
}

variable "create_ingress" {
  type    = bool
  default = false
}

variable "nginx_ingress_version" {
  type    = string
  default = "6.0.24"
}

variable "nginx_ingress_controller_tag" {
  description = "Controller image tag v<controller>_<addon>; must end with _<resolved addon version>"
  type        = string
  default     = "v1.14.5_6.0.24"
}

variable "ingress_eip_bandwidth" {
  description = "Ingress ELB EIP bandwidth in Mbit/s"
  type        = number
  default     = 100
}

variable "ingress_preserve_client_ip" {
  description = "Use externalTrafficPolicy Local on the ingress Service to preserve client source IPs"
  type        = bool
  default     = true
}

variable "dns_zone_id" {
  type    = string
  default = null
}

variable "dns_zone_name" { type = string }

variable "create_dns_record" {
  type    = bool
  default = false
}

variable "create_lts" {
  type    = bool
  default = false
}

variable "lts_ttl_days" {
  type    = number
  default = 7
}

variable "log_agent_version" {
  type    = string
  default = "1.7.10"
}
