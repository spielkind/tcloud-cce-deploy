# =============================================================================
# LTS Log Group + Streams
# =============================================================================

# =============================================================================
# Log Group
# =============================================================================
resource "opentelekomcloud_lts_group_v2" "openbao" {
  count       = var.enable_lts_logging ? 1 : 0
  group_name  = "${var.name_prefix}-openbao-logs"
  ttl_in_days = var.lts_ttl_days
  tags        = var.tags
}

# =============================================================================
# Log Streams
# =============================================================================
resource "opentelekomcloud_lts_stream_v2" "audit" {
  count       = var.enable_lts_logging ? 1 : 0
  group_id    = opentelekomcloud_lts_group_v2.openbao[0].id
  stream_name = "${var.name_prefix}-openbao-audit"
  tags        = var.tags
}

resource "opentelekomcloud_lts_stream_v2" "security" {
  count       = var.enable_lts_logging ? 1 : 0
  group_id    = opentelekomcloud_lts_group_v2.openbao[0].id
  stream_name = "${var.name_prefix}-openbao-security"
  tags        = var.tags
}

resource "opentelekomcloud_lts_stream_v2" "system" {
  count       = var.enable_lts_logging ? 1 : 0
  group_id    = opentelekomcloud_lts_group_v2.openbao[0].id
  stream_name = "${var.name_prefix}-openbao-system"
  tags        = var.tags
}

resource "opentelekomcloud_lts_stream_v2" "cloud_init" {
  count       = var.enable_lts_logging ? 1 : 0
  group_id    = opentelekomcloud_lts_group_v2.openbao[0].id
  stream_name = "${var.name_prefix}-openbao-cloud-init"
  tags        = var.tags
}

# =============================================================================
# Host Groups
# =============================================================================
# Hosts auto-join via custom_tag file matching the label (see user_data)
resource "opentelekomcloud_lts_host_group_v3" "nodes" {
  count             = var.enable_lts_logging ? 1 : 0
  name              = "${var.name_prefix}-openbao-nodes"
  type              = "linux"
  agent_access_type = "LABEL"
  labels            = ["${var.name_prefix}-openbao-node"]
  tags              = var.tags

  lifecycle {
    ignore_changes = [host_ids]
  }
}

resource "opentelekomcloud_lts_host_group_v3" "bastion" {
  count             = var.enable_lts_logging && var.enable_bastion ? 1 : 0
  name              = "${var.name_prefix}-openbao-bastion"
  type              = "linux"
  agent_access_type = "LABEL"
  labels            = ["${var.name_prefix}-openbao-bastion"]
  tags              = var.tags

  lifecycle {
    ignore_changes = [host_ids]
  }
}

locals {
  lts_all_host_group_ids = var.enable_lts_logging ? concat(
    [opentelekomcloud_lts_host_group_v3.nodes[0].id],
    var.enable_bastion ? [opentelekomcloud_lts_host_group_v3.bastion[0].id] : [],
  ) : []

  lts_nodes_host_group_ids = var.enable_lts_logging ? [
    opentelekomcloud_lts_host_group_v3.nodes[0].id
  ] : []

  # Host access names only allow letters, digits, underscores, and periods
  lts_name_prefix = replace(var.name_prefix, "-", "_")
}

# =============================================================================
# Host Access Configs (file path → stream mapping)
# =============================================================================
resource "opentelekomcloud_lts_host_access_v3" "audit" {
  count          = var.enable_lts_logging ? 1 : 0
  name           = "${local.lts_name_prefix}_openbao_audit"
  log_group_id   = opentelekomcloud_lts_group_v2.openbao[0].id
  log_stream_id  = opentelekomcloud_lts_stream_v2.audit[0].id
  host_group_ids = local.lts_nodes_host_group_ids

  access_config {
    paths = ["/var/log/openbao/audit.log"]

    single_log_format {
      mode = "system"
    }
  }

  tags = var.tags
}

resource "opentelekomcloud_lts_host_access_v3" "security" {
  count          = var.enable_lts_logging ? 1 : 0
  name           = "${local.lts_name_prefix}_openbao_security"
  log_group_id   = opentelekomcloud_lts_group_v2.openbao[0].id
  log_stream_id  = opentelekomcloud_lts_stream_v2.security[0].id
  host_group_ids = local.lts_all_host_group_ids

  access_config {
    paths = ["/var/log/auth.log", "/var/log/fail2ban.log"]

    single_log_format {
      mode = "system"
    }
  }

  tags = var.tags
}

resource "opentelekomcloud_lts_host_access_v3" "system" {
  count          = var.enable_lts_logging ? 1 : 0
  name           = "${local.lts_name_prefix}_openbao_system"
  log_group_id   = opentelekomcloud_lts_group_v2.openbao[0].id
  log_stream_id  = opentelekomcloud_lts_stream_v2.system[0].id
  host_group_ids = local.lts_all_host_group_ids

  access_config {
    paths = ["/var/log/syslog"]

    single_log_format {
      mode = "system"
    }
  }

  tags = var.tags
}

resource "opentelekomcloud_lts_host_access_v3" "cloud_init" {
  count          = var.enable_lts_logging ? 1 : 0
  name           = "${local.lts_name_prefix}_openbao_cloud_init"
  log_group_id   = opentelekomcloud_lts_group_v2.openbao[0].id
  log_stream_id  = opentelekomcloud_lts_stream_v2.cloud_init[0].id
  host_group_ids = local.lts_all_host_group_ids

  access_config {
    paths = ["/var/log/cloud-init-output.log"]

    single_log_format {
      mode = "system"
    }
  }

  tags = var.tags
}
