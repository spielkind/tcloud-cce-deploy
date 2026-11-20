# Feature flags
create_podinfo  = true
create_openbao  = true
create_demo_app = true

# Versions
cert_manager_version  = "v1.21.3"
podinfo_version       = "6.17.0"
openbao_chart_version = "0.30.8"

# OpenBao
openbao_replicas     = 3
openbao_hostname     = "openbao"
openbao_storage_size = "10Gi"

# Demo App
demo_app_hostname = "demo"
