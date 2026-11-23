# Documentation

| Document | Topic | Diagram |
|---|---|---|
| [../README.md](../README.md) | Overview, environments, prerequisites, CI, variables, outputs | [architecture.svg](diagrams/architecture.svg) |
| [logging.md](logging.md) | Logging and audit: log-agent, LTS streams, OpenBao audit, CTS, VPC flow logs | [logging.svg](diagrams/logging.svg) |
| [monitoring.md](monitoring.md) | Monitoring options (self-hosted Prometheus, AOM, CES + LTS) with trade-offs — not implemented | [monitoring-options.svg](diagrams/monitoring-options.svg) |
| [openbao.md](openbao.md) | OpenBao on CCE (`openbao_mode = "cce"`): setup, injector, audit, backup | [openbao.svg](diagrams/openbao.svg) |
| [openbao-unseal.md](openbao-unseal.md) | Auto-unseal via init container, FunctionGraph, KMS and OBS | [openbao-unseal.svg](diagrams/openbao-unseal.svg) |
| [openbao-vm.md](openbao-vm.md) | OpenBao on dedicated VMs (`openbao_mode = "vm"`) | [openbao-vm.svg](diagrams/openbao-vm.svg) |
| [workload-identity.md](workload-identity.md) | OIDC workload identity for pods (no AK/SK) | [workload-identity.svg](diagrams/workload-identity.svg) |
| [demo-app.md](demo-app.md) | OpenBao demo app: sidecar vs. API access | [demo-app.svg](diagrams/demo-app.svg) |
| [gpu.md](gpu.md) | GPU node pool and GPU AI playground (image, chat, speech, vision) | [gpu.svg](diagrams/gpu.svg) |

All diagrams live in [diagrams/](diagrams/) (hand-written SVG, no version numbers). Render locally with `rsvg-convert -w 1400 diagrams/<name>.svg -o /tmp/<name>.png`.
