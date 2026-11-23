# OpenBao placement (disabled | cce | vm) comes from infra's openbao_mode.
environment          = "dev"
create_podinfo       = true
create_openbao       = true
create_demo_app      = true
demo_app_access_mode = "both"
demo_app_hostname    = "demo"
create_gpu_demo      = true
gpu_demo_hostname    = "aidemo"
gpu_demo_replicas    = 1 # 0 = scale the GPU node to zero
