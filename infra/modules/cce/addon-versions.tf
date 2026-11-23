# =============================================================================
# Addon template lookup and version resolution
# Each *_version variable accepts a pinned version or "latest", which resolves
# to the highest template version supported for var.cluster_version.
# swr_addr/swr_user/obs_url are taken from the selected template and fall back
# to the regional defaults if the template is not listed.
# =============================================================================
locals {
  autoscaler_enabled = local.any_autoscaling
  xgpu_enabled       = local.gpu_enabled && var.gpu_xgpu

  addon_enabled = {
    autoscaler     = local.autoscaler_enabled
    gpu-beta       = local.gpu_enabled
    log-agent      = var.create_lts
    metrics-server = var.create_metrics_server
    nginx-ingress  = var.create_ingress
    volcano        = local.xgpu_enabled
  }

  addon_requested_version = {
    autoscaler     = var.autoscaler_version
    gpu-beta       = var.gpu_addon_version
    log-agent      = var.log_agent_version
    metrics-server = var.metrics_server_version
    nginx-ingress  = var.nginx_ingress_version
    volcano        = var.volcano_version
  }
}

data "opentelekomcloud_cce_addon_templates_v3" "this" {
  for_each = { for name, enabled in local.addon_enabled : name => name if enabled }

  cluster_version = var.cluster_version
  cluster_type    = var.cluster_type
  addon_name      = each.key
}

locals {
  # Zero-padded "major minor patch" sort key => version, so a lexical sort
  # orders versions semantically.
  _addon_sort_keys = {
    for name, d in data.opentelekomcloud_cce_addon_templates_v3.this : name => {
      for a in d.addons : join("", [
        for part in slice(concat(split(".", a.addon_version), ["0", "0", "0"]), 0, 3) :
        format("%06d", try(tonumber(part), 0))
      ]) => a.addon_version... if can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", a.addon_version))
    }
  }

  addon_latest_version = {
    for name, keys_map in local._addon_sort_keys : name =>
    length(keys_map) > 0 ? keys_map[reverse(sort(keys(keys_map)))[0]][0] : null
  }

  addon_version = {
    for name, requested in local.addon_requested_version : name =>
    requested == "latest" ? lookup(local.addon_latest_version, name, null) : requested
  }

  addon_template = {
    for name, d in data.opentelekomcloud_cce_addon_templates_v3.this : name =>
    one([for a in d.addons : a if a.addon_version == local.addon_version[name]])
  }

  addon_swr_addr = {
    for name in keys(local.addon_enabled) : name =>
    try(coalesce(local.addon_template[name].swr_addr), "swr.${local.service_domain}")
  }

  addon_swr_user = {
    for name in keys(local.addon_enabled) : name =>
    try(coalesce(local.addon_template[name].swr_user), "cce-addons")
  }
}
