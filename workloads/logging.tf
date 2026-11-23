# =============================================================================
# Node log files -> LTS (log-agent LogConfig CRDs)
# The CCE log-agent addon (fluent-bit + log-operator) replaces the legacy
# ICAgent. Its default LogConfigs ship container stdout and events; these
# host_file LogConfigs add node logs to the "hostfile" stream created by infra.
# =============================================================================
locals {
  lts_group_id           = try(local.infra.lts_group_id, "")
  lts_hostfile_stream_id = try(local.infra.lts_hostfile_stream_id, "")
  node_logs_enabled      = var.node_log_collection && local.lts_hostfile_stream_id != ""
}

resource "kubernetes_manifest" "node_log" {
  for_each = local.node_logs_enabled ? var.node_log_files : {}

  manifest = {
    apiVersion = "logging.openvessel.io/v1"
    kind       = "LogConfig"
    metadata = {
      name      = each.key
      namespace = "kube-system"
    }
    spec = {
      inputDetail = {
        type = "host_file"
        hostFile = {
          file = {
            logPath     = each.value.path
            filePattern = each.value.pattern
          }
        }
      }
      outputDetail = {
        type = "LTS"
        LTS = {
          ltsGroupID  = local.lts_group_id
          ltsStreamID = local.lts_hostfile_stream_id
        }
      }
    }
  }

  # The log-operator writes defaults and status back into spec (verified on log-agent 1.7.10).
  computed_fields = [
    "metadata.annotations",
    "metadata.labels",
    "spec.logConfigStatus",
    "spec.inputDetail.containerFile",
    "spec.inputDetail.containerStdout",
    "spec.inputDetail.event",
    "spec.inputDetail.processors",
    "spec.outputDetail.AOM",
    "spec.outputDetail.kafka",
    "spec.outputDetail.LTS.isCustomised",
    "spec.outputDetail.LTS.ltsGroupCreateParam",
    "spec.outputDetail.LTS.ltsStreamCreateParam",
  ]
}
