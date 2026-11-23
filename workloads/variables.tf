# =============================================================================
# Versions
# =============================================================================
variable "environment" {
  description = "Deployment environment; reads the infra state from <environment>/infra/terraform.tfstate (no default, so a missing -var-file fails instead of reading dev)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.21.3"
}

variable "podinfo_version" {
  description = "podinfo Helm chart version"
  type        = string
  default     = "6.17.0"
}

variable "openbao_chart_version" {
  description = "OpenBao Helm chart version"
  type        = string
  default     = "0.30.8"
}

# =============================================================================
# Feature flags
# =============================================================================
variable "create_podinfo" {
  description = "Deploy podinfo hello world app"
  type        = bool
  default     = true
}

variable "create_openbao" {
  description = "Deploy the in-cluster OpenBao parts for infra's openbao_mode: cce = HA Raft server + Agent Injector, vm = Agent Injector for the VM cluster"
  type        = bool
  default     = false
}

variable "create_demo_app" {
  description = "Deploy the OpenBao integration demo (requires OpenBao in CCE or VM mode)"
  type        = bool
  default     = false
}

variable "demo_app_access_mode" {
  description = "OpenBao integration demonstrated by the app: injected read-only, direct Kubernetes-auth API, or both"
  type        = string
  default     = "both"
  validation {
    condition     = contains(["agent", "api", "both"], var.demo_app_access_mode)
    error_message = "demo_app_access_mode must be agent, api, or both."
  }
}

# =============================================================================
# OpenBao
# =============================================================================
variable "openbao_replicas" {
  description = "Number of OpenBao server replicas (odd numbers for Raft quorum)"
  type        = number
  default     = 3
}

variable "openbao_hostname" {
  description = "Subdomain for OpenBao UI/API (prepended to DNS zone)"
  type        = string
  default     = "openbao"
}

variable "openbao_storage_size" {
  description = "PVC size per OpenBao replica"
  type        = string
  default     = "10Gi"
}

# =============================================================================
# Demo App
# =============================================================================
variable "demo_app_hostname" {
  description = "Subdomain for demo app"
  type        = string
  default     = "demo"
}

variable "demo_app_image_tag" {
  description = "Demo app image tag in SWR (CI sets the commit SHA of the last image build)"
  type        = string
  default     = "latest"
}

# =============================================================================
# GPU Demo
# =============================================================================
variable "create_gpu_demo" {
  description = "Deploy the GPU text-to-image demo (requires a node pool with gpu = true in infra)"
  type        = bool
  default     = false
}

variable "gpu_demo_hostname" {
  description = "Subdomain for the GPU demo"
  type        = string
  default     = "aidemo"
}

variable "gpu_demo_replicas" {
  description = "0 = GPU node is scaled down by the autoscaler (~10 min), 1 = GPU node is running"
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.gpu_demo_replicas)
    error_message = "gpu_demo_replicas must be 0 or 1 (one GPU per node)."
  }
}

variable "gpu_demo_models" {
  description = "Hugging Face models per GPU demo tab (loaded on first use; least recently used is unloaded when VRAM is short)"
  type = object({
    image  = optional(string, "stabilityai/sdxl-turbo")             # text->image + image->image (Stability AI non-commercial license)
    chat   = optional(string, "Qwen/Qwen2.5-3B-Instruct")           # chat (Qwen Research License)
    stt    = optional(string, "openai/whisper-large-v3-turbo")      # speech->text (MIT)
    vision = optional(string, "florence-community/Florence-2-base") # caption, OCR, detection (MIT)
  })
  default = {}
}

variable "gpu_demo_openbao" {
  description = "Inject the Hugging Face token from OpenBao (kv/gpu-demo/hf, see scripts/gpu-demo-openbao-setup.sh); needs OpenBao"
  type        = bool
  default     = true
}

variable "gpu_slicing" {
  description = <<-EOT
    GPU slicing showcase (needs gpu_xgpu = true in infra, docs/gpu.md#gpu-slicing). enabled = null follows infra.
    The playground and each worker get a hard xGPU slice of the L4: mem_gib (multiple of 0.125) and core_percent.
  EOT
  type = object({
    enabled = optional(bool)
    playground = optional(object({
      mem_gib      = number
      core_percent = number
    }), { mem_gib = 13, core_percent = 50 })
    workers = optional(list(object({
      name         = string
      mem_gib      = number
      core_percent = number
      })), [
      { name = "small", mem_gib = 2, core_percent = 10 },
      { name = "medium", mem_gib = 3, core_percent = 15 },
      { name = "large", mem_gib = 4, core_percent = 25 },
    ])
  })
  default = {}

  validation {
    condition = alltrue([
      for s in concat([var.gpu_slicing.playground], var.gpu_slicing.workers) :
      s.mem_gib >= 1 && floor(s.mem_gib * 8) == s.mem_gib * 8 && s.core_percent >= 1 && s.core_percent <= 100 && floor(s.core_percent) == s.core_percent
    ])
    error_message = "Each slice needs mem_gib >= 1 (multiple of 0.125) and an integer core_percent between 1 and 100."
  }

  validation {
    condition = (
      sum(concat([var.gpu_slicing.playground.mem_gib], [for w in var.gpu_slicing.workers : w.mem_gib])) <= 22 &&
      sum(concat([var.gpu_slicing.playground.core_percent], [for w in var.gpu_slicing.workers : w.core_percent])) <= 100
    )
    error_message = "All slices together must fit one L4: at most 22 GiB VRAM and 100 % compute."
  }

  validation {
    condition = alltrue([for w in var.gpu_slicing.workers : can(regex("^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$", w.name))]) && (
      length(distinct([for w in var.gpu_slicing.workers : w.name])) == length(var.gpu_slicing.workers)
    )
    error_message = "Worker names must be unique DNS labels (lowercase, max 20 characters)."
  }
}

variable "gpu_demo_image_tag" {
  description = "GPU demo image tag in SWR (CI sets the commit SHA of the last image build)"
  type        = string
  default     = "latest"
}

variable "openbao_audit_enabled" {
  description = "Enable the declarative OpenBao audit device (stdout -> LTS) in cce mode; applied on the next pod restart"
  type        = bool
  default     = true
}

variable "node_log_collection" {
  description = "Create log-agent LogConfigs that ship node log files to the cluster LTS hostfile stream"
  type        = bool
  default     = true
}

variable "node_log_files" {
  description = "Node log files collected when node_log_collection is true (LogConfig name => directory and file pattern)"
  type = map(object({
    path    = string
    pattern = string
  }))
  default = {
    "node-messages"   = { path = "/var/log", pattern = "messages" }                  # systemd/journald incl. kubelet, containerd
    "node-secure"     = { path = "/var/log", pattern = "secure" }                    # sshd/sudo/auth
    "node-cce-agents" = { path = "/var/paas/sys/log/kubernetes", pattern = "*.log" } # autoscaler, everest CSI
  }
  validation {
    condition     = alltrue([for k, v in var.node_log_files : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", k)) && can(regex("^/[a-zA-Z0-9_/*?-]*$", v.path))])
    error_message = "node_log_files keys must be DNS labels and paths absolute without special characters."
  }
}
