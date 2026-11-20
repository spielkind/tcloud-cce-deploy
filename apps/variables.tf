# =============================================================================
# Versions
# =============================================================================
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
  description = "Deploy OpenBao (HA Raft + Agent Injector)"
  type        = bool
  default     = false
}

variable "create_demo_app" {
  description = "Deploy OpenBao demo app (requires create_openbao)"
  type        = bool
  default     = false
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
