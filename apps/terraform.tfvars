# Feature flags
create_podinfo = true
create_vault   = true

# Versions
cert_manager_version = "1.17.1"
vault_chart_version  = "0.29.1"

# Vault
vault_replicas     = 3
vault_hostname  = "myvault"
vault_storage_size = "10Gi"

# Demo App
create_demo_app    = true
demo_app_hostname  = "demo"
otc_project_name = "eu-de_MIC_POC"
