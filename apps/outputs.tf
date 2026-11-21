output "app_url" {
  value = var.create_podinfo ? "https://hello.${local.zone_name}" : null
}

output "openbao_url" {
  value = var.create_openbao ? "https://${var.openbao_hostname}.${local.zone_name}" : null
}

output "demo_app_url" {
  value = var.create_demo_app ? "https://${var.demo_app_hostname}.${local.zone_name}" : null
}

output "demo_app_image_tag" {
  value = var.create_openbao && var.create_demo_app ? var.demo_app_image_tag : null
}

output "gpu_demo_url" {
  value = local.gpu_demo_enabled ? "https://${var.gpu_demo_hostname}.${local.zone_name}" : null
}

output "gpu_demo_image_tag" {
  value = local.gpu_demo_enabled ? var.gpu_demo_image_tag : null
}
