# STATUS: template — prod is not configured yet. Fill in real values and remove this line to enable it.
# OpenBao placement (disabled | cce | vm) comes from infra's openbao_mode.
environment       = "prod"
create_podinfo    = false # needs create_ingress + create_dns in infra
create_openbao    = false
create_demo_app   = false
create_gpu_demo   = false
demo_app_hostname = "demo"
gpu_demo_hostname = "aidemo"
