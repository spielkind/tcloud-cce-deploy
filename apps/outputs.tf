output "app_url" {
  value = var.create_podinfo ? "https://hello.${local.zone_name}" : null
}

output "vault_url" {
  value = var.create_vault ? "https://${var.vault_hostname}.${local.zone_name}" : null
}

output "demo_app_url" {
  value = var.create_demo_app ? "https://${var.demo_app_hostname}.${local.zone_name}" : null
}
