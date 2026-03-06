# =============================================================================
# App versions
# =============================================================================
variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "1.17.1"
}

variable "vault_chart_version" {
  description = "Vault Helm chart version"
  type        = string
  default     = "0.29.1"
}

# =============================================================================
# Feature flags
# =============================================================================
variable "create_podinfo" {
  description = "Deploy podinfo hello world app"
  type        = bool
  default     = true
}

variable "create_vault" {
  description = "Deploy HashiCorp Vault (HA + Injector)"
  type        = bool
  default     = false
}

# =============================================================================
# Vault
# =============================================================================
variable "vault_replicas" {
  description = "Number of Vault server replicas (odd numbers for Raft quorum)"
  type        = number
  default     = 3
}

variable "vault_hostname" {
  description = "Subdomain for Vault UI/API (prepended to DNS zone)"
  type        = string
  default     = "vault"
}

variable "vault_storage_size" {
  description = "PVC size per Vault replica"
  type        = string
  default     = "10Gi"
}

# =============================================================================
# Demo App
# =============================================================================
variable "create_demo_app" {
  description = "Deploy Vault demo app"
  type        = bool
  default     = false
}

variable "demo_app_hostname" {
  description = "Subdomain for demo app"
  type        = string
  default     = "demo"
}



variable "otc_project_name" {
  description = "OTC project name (e.g. eu-de_MIC_POC)"
  type        = string
}
