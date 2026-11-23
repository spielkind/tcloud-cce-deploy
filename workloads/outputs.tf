output "app_url" {
  value = var.create_podinfo ? "https://hello.${local.zone_name}" : null
}

output "openbao_mode" {
  description = "OpenBao placement from infra (disabled, cce or vm)"
  value       = local.selected_bao_mode
}

output "openbao_url" {
  description = "Public OpenBao API/UI URL (in-cluster ingress for cce, VM ELB for vm)"
  value       = local.openbao_cce_enabled ? local.openbao_cce_url : (local.selected_bao_mode == "vm" ? local.openbao_vm_url : null)
}

# Kubernetes auth settings for the external (vm mode) OpenBao cluster; consumed
# by scripts/demo-app-openbao-setup.sh.
output "openbao_kubernetes_host" {
  description = "Kubernetes API URL the VM OpenBao cluster uses for TokenReview (vm mode)"
  value       = local.openbao_vm_enabled ? local.api_host : null
}

output "openbao_kubernetes_ca_cert" {
  description = "Cluster CA PEM for the OpenBao Kubernetes auth method (vm mode)"
  value       = local.openbao_vm_enabled ? base64decode(local.infra.cluster_ca_cert) : null
}

output "openbao_token_reviewer_jwt" {
  description = "Token reviewer JWT for the OpenBao Kubernetes auth method (vm mode)"
  value       = local.openbao_vm_enabled ? kubernetes_secret_v1.openbao_token_reviewer[0].data["token"] : null
  sensitive   = true
}

output "demo_app_url" {
  value = var.create_demo_app && local.openbao_enabled ? "https://${var.demo_app_hostname}.${local.zone_name}" : null
}

output "demo_app_image_tag" {
  value = var.create_demo_app && local.openbao_enabled ? var.demo_app_image_tag : null
}

output "gpu_demo_url" {
  value = local.gpu_demo_enabled ? "https://${var.gpu_demo_hostname}.${local.zone_name}" : null
}

output "gpu_demo_image_tag" {
  value = local.gpu_demo_enabled ? var.gpu_demo_image_tag : null
}
