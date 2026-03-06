# T-Cloud CCE Deployment — OpenTofu + GitHub Actions

> ⚠️ **Proof of Concept** — This repository is a POC for testing T-Cloud/OTC features and Terraform resources. It is **not production-ready** and does **not** represent best practices. Use at your own risk.

Infrastructure-as-Code for deploying a managed Kubernetes cluster (CCE) on T-Cloud.

## Architecture

![Architecture](docs/architecture.svg)

## What Gets Created

**Bootstrap** (separate project, run once locally):

| Resource | Details |
|---|---|
| OBS Bucket | OpenTofu state backend (KMS-encrypted, versioned) |
| KMS Key | Encrypts state bucket |

**Infra** (main project — `infra/`):

| Resource | Details |
|---|---|
| VPC + Subnet | Single subnet (or separate ENI subnet for Yangtse) |
| Security Group | Managed by CCE, extended with custom rules |
| CCE Cluster | CCE Standard (overlay_l2/vpc-router) or CCE Turbo (eni/Yangtse) |
| Node Pool | Configurable flavor/count, optional autoscaling |
| SSH Key Pair | From your public key |
| IAM Agency | `cce_admin_trust` — CCE trust delegation |
| DNS Zone | Public or private zone (optional) |
| ELB + EIP | LoadBalancer for nginx-ingress (optional) |
| nginx-ingress | CCE addon with ELB binding (optional) |
| Wildcard DNS | `*.your-domain` → ELB IP (optional) |
| CCE API EIP | Public kubectl access (optional) |
| NAT Gateway | Internet access for worker nodes |
| LTS Streams | stdout, containerfile, hostfile, event streams in auto-created log group (optional) |
| log-agent | CCE log collection addon — fluent-bit + otel-collector (optional) |
| KMS Key | Encrypts Vault unseal keys at rest (optional) |
| OBS Bucket | Stores encrypted unseal keys (optional) |
| FunctionGraph | Auto-unseal function — reads OBS, decrypts KMS, unseals Vault (optional) |
| Identity Provider | OIDC workload identity — pod-to-API auth without AK/SK (optional) |

**Apps** (separate project — `apps/`):

| Resource | Details |
|---|---|
| cert-manager | TLS certificate automation (Let's Encrypt) |
| podinfo | Hello world app with ingress (optional) |
| Vault | HA secrets management with Raft storage + Injector (optional) |
| Demo App | Python app — reads/writes Vault secrets, image from SWR (optional) |

See [Vault documentation](docs/vault.md) for setup & usage.
See [Vault Auto-Unseal](docs/vault-unseal.md) for event-driven unsealing with FunctionGraph + KMS.
See [Workload Identity](docs/workload-identity.md) for OIDC-based pod authentication (no AK/SK).
See [Demo App documentation](docs/demo-app.md) for the Vault + SWR demo.

## Prerequisites

- **T-Cloud Account** with AK/SK ([how to create](#otc-credentials--iam-permissions))
- **GitHub repo** with Actions enabled
- **DNS delegation** (if using custom domain): set NS records at your registrar pointing to `ns1.open-telekom-cloud.com` and `ns2.open-telekom-cloud.com`

---

## T-Cloud Credentials & IAM Permissions

### 1. Create User Group

T-Cloud Console → **IAM → User Groups → Create User Group**

### 2. Create a Technical User

T-Cloud Console → **IAM → Users → Create User**

| Setting | Value |
|---|---|
| Access type | **Programmatic access** only |
| User group | The group from step 1 |

### 3. Create Access Key (AK/SK)

**IAM → Users → your user → Security Settings → Access Keys → Create**

> ⚠️ The Secret Key (SK) is shown **only once**. Save it immediately.

### 4. Required Permissions

Assign to the user group:

**Project-level** (scope: your project, e.g. `eu-de_MIC_POC`):

| Role | Purpose |
|---|---|
| `Tenant Guest` | Base read access |
| `CCE Administrator` | CCE cluster management |
| `CCE Admin` | CCE cluster admin |
| `VPC Admin` | VPC, Subnets |
| `VPC Administrator` | VPC full access |
| `ECS Admin` | Worker node instances |
| `Server Administrator` | Server management |
| `ELB Administrator` | LoadBalancer services |
| `DNS Administrator` | DNS zones |
| `CES Administrator` | Monitoring |
| `NAT Gateway Administrator` | NAT gateway for node internet access |
| `NAT FullAccess` | NAT gateway tagging |
| `RDS Administrator` | RDS (if needed) |

**All resources** (scope: all existing and future projects):

| Role | Purpose |
|---|---|
| `Security Administrator` | IAM agency creation (`cce_admin_trust`) |
| `OBS Administrator` | OpenTofu state bucket |
| `KMS Administrator` | Encryption keys for state bucket |
| `SWR Administrator` | Container image registry |
| `LTS Administrator` | Log Tank Service |
| `LTS FullAccess` | LTS full access |

### 5. Find Your Domain Name

T-Cloud Console → top-right dropdown → **My Credentials** → **Domain Name**

---

## Setup

### GitHub Secrets

**Settings → Secrets and variables → Actions → Secrets:**

| Secret | Description |
|---|---|
| `OTC_ACCESS_KEY` | Access Key ID |
| `OTC_SECRET_KEY` | Secret Access Key |
| `OTC_DOMAIN_NAME` | Domain name from My Credentials |

No other secrets or variables needed — everything else lives in `terraform.tfvars`.

---

## Security Best Practice: OIDC (Optional)
Currently, GitHub Actions relies on long-lived `OTC_ACCESS_KEY` & `OTC_SECRET_KEY` credentials. For enterprise and production workloads, it is recommended to set up an **OIDC IdP (OpenID Connect)** inside T-Cloud IAM. 
This allows GitHub Actions to assume a T-Cloud agency without storing static credentials in GitHub Secrets.

---

## Workflows

### 1. Bootstrap (run once, locally)

Creates the OBS bucket + KMS key for OpenTofu state. Uses a separate project (`bootstrap/`) with local state.

```bash
export TF_VAR_otc_access_key="your-ak"
export TF_VAR_otc_secret_key="your-sk"
export TF_VAR_otc_domain_name="your-domain"
./scripts/bootstrap.sh
```

This will:
1. Create OBS bucket (KMS-encrypted, versioned) + KMS key
2. Write the S3 backend config to `infra/backend.tf` and `apps/backend.tf`

> ⚠️ Bootstrap state is local on your machine. Keep it safe or re-import if lost.

After bootstrap, commit and push:
```bash
git add infra/backend.tf apps/backend.tf
git commit -m "chore: add backend config from bootstrap"
git push
```

### 2. Deploy (GitHub Actions)

The deploy workflow has two jobs:

1. **Infra** — VPC, CCE, DNS, Ingress, ELB (always runs)
2. **Apps** — Helm releases like podinfo (only runs on apply, after infra)

**Actions → Deploy → Run workflow**

- Run without "Apply" → plan only (also runs on PRs to `main`)
- Run with "Apply" → plan + apply (infra first, then apps)

### 3. Destroy

Tears down infra resources (VPC, CCE, nodes, etc.). Does **not** delete the OBS bucket, KMS key, or apps state.

**Actions → Destroy → Run workflow**

- Run without "Apply" → destroy plan only
- Run with "Apply" + type `destroy` in confirm field → executes destroy

> ⚠️ Destroy apps first if deployed: `cd apps && tofu destroy`

### Local Usage

You can run OpenTofu locally instead of through GitHub Actions:

```bash
# Only credentials as env vars — everything else is in terraform.tfvars
export TF_VAR_otc_access_key="your-ak"
export TF_VAR_otc_secret_key="your-sk"
export TF_VAR_otc_domain_name="your-domain"
export AWS_ACCESS_KEY_ID="$TF_VAR_otc_access_key"
export AWS_SECRET_ACCESS_KEY="$TF_VAR_otc_secret_key"

# Infra
cd infra
tofu init
tofu plan
tofu apply

# Apps (after infra is deployed)
cd ../apps
tofu init
tofu plan
tofu apply
```

> ⚠️ Do **not** set `AWS_SESSION_TOKEN` — OBS will reject the credentials.

---

## Variables

### Credentials (env vars / GitHub Secrets — never in files!)

| Variable | Example |
|---|---|
| `TF_VAR_otc_access_key` | `ABCDEF1234567890` |
| `TF_VAR_otc_secret_key` | `aBcDeFgHiJkLmNoPqRsT...` |
| `TF_VAR_otc_domain_name` | `OTC00000000001000000123` |

All other settings (project name, SSH key, cluster config) are in `terraform.tfvars`.

### Infrastructure (`terraform.tfvars`)

| Variable | Default | Description |
|---|---|---|
| `otc_project_name` | `eu-de` | T-Cloud project name |
| `name_prefix` | `mic` | Prefix for all resource names |
| `region` | `eu-de` | T-Cloud region |
| `vpc_cidr` | `10.248.0.0/16` | VPC address space |
| `subnet_cidr` | auto `/24` | Node subnet CIDR (must be within VPC) |
| `eni_subnet_cidr` | — | Separate pod subnet for Yangtse (empty = shared with nodes) |
| `bastion_cidrs` | `[]` | CIDRs allowed for SSH to nodes |
| `cluster_version` | `v1.32` | Kubernetes version |
| `cluster_flavor` | `cce.s1.small` | Cluster size (see below) |
| `cluster_type` | `VirtualMachine` | `VirtualMachine` (ECS nodes) or `BareMetal` (BMS nodes) |
| `container_network_type` | `overlay_l2` | Network mode — determines Standard vs Turbo cluster (see below) |
| `high_availability` | `false` | HA cluster (3 masters across AZs) |
| `kube_proxy_mode` | `iptables` | `iptables` or `ipvs` |
| `node_flavor` | `s3.xlarge.2` | Worker node ECS flavor (must match cluster type — see below) |
| `node_count` | `3` | Number of worker nodes |
| `ssh_public_key` | — | **Required** — SSH public key |
| `autoscaling_enabled` | `false` | Node pool autoscaling |
| `bind_api_eip` | `false` | Bind public EIP to CCE API (kubectl from internet) |
| `create_dns` | `false` | Create a DNS zone |
| `dns_zone_name` | `cluster.internal.` | DNS zone name (trailing dot!) |
| `dns_zone_type` | `public` | `public` or `private` |
| `create_ingress` | `false` | Install nginx-ingress addon + ELB + wildcard DNS |
| `create_lts` | `false` | Enable CCE log-agent addon for LTS logging |
| `log_agent_version` | `1.7.6` | CCE log-agent addon version |
| `nginx_ingress_version` | `5.0.2` | CCE nginx-ingress addon version |

### Applications (`apps/terraform.tfvars`)

| Variable | Default | Description |
|---|---|---|
| `create_vault` | `false` | Deploy HashiCorp Vault (HA + Injector) |
| `vault_replicas` | `3` | Vault server replicas |
| `vault_hostname` | `vault` | Subdomain for Vault UI (`vault.<zone>`) |
| `create_podinfo` | `false` | Deploy podinfo demo app |
| `otc_project_name` | — | OTC project name for Workload Identity (e.g. `eu-de_MIC_POC`) |

**Container network modes:**

| Mode | Value | Cluster Type | Pod IPs | Network Isolation |
|---|---|---|---|---|
| **Canal (Tunnel)** | `overlay_l2` | CCE Standard | Cluster-internal only | ✅ Kubernetes NetworkPolicy |
| **VPC Router** | `vpc-router` | CCE Standard | VPC-routable | ❌ none |
| **Cloud Native 2.0 (Yangtse)** | `eni` | CCE Turbo | VPC-routable (ENI) | ✅ Security Groups per pod |

> **CCE Turbo** = `container_network_type = "eni"`. In the T-Cloud Console this creates a "CCE Turbo" cluster; in Terraform it's the same `cce_cluster_v3` resource with `cluster_type = "VirtualMachine"`. Set `eni_subnet_cidr` for a dedicated pod subnet (recommended: `/18` or larger).
>
> **⚠️ Node Flavors:** Standard and Turbo clusters require **different ECS flavors**. Turbo clusters need network-enhanced flavors (e.g. `s7n`, `c7n`, `m7n`, `c3n`) that support sub-ENIs. Standard flavors like `s3` or `c4` will **not work** with Turbo/eni mode. See [Node Flavor Description](https://docs.otc.t-systems.com/cloud-container-engine/api-ref/appendix/node_flavor_description.html) for the full list.

> ⚠️ **Network mode is immutable** — changing it requires a cluster rebuild.

**Cluster flavors:**

| Flavor | Masters | Max nodes |
|---|---|---|
| `cce.s1.small` | 1 | 50 |
| `cce.s1.medium` | 1 | 200 |
| `cce.s2.small` | 3 (HA) | 50 |
| `cce.s2.medium` | 3 (HA) | 200 |

**Node flavors (must match cluster type):**

| Flavor | vCPU | RAM | Cluster Type | Use case |
|---|---|---|---|---|
| `s3.large.2` | 2 | 4 GB | Standard | Dev/Test |
| `s3.xlarge.2` | 4 | 8 GB | Standard | Production |
| `s7n.large.2` | 2 | 4 GB | Turbo (eni) | Dev/Test |
| `s7n.xlarge.2` | 4 | 8 GB | Turbo (eni) | Production |
| `c7n.xlarge.2` | 4 | 8 GB | Turbo (eni) | Compute-intensive |

---

## Project Structure

```
├── bootstrap/
│   └── main.tf              # OBS bucket + KMS key (local state)
├── infra/               # Infra project (VPC, CCE, DNS, Ingress)
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── resources.tf
│   ├── outputs.tf
│   └── modules/
│       ├── vpc/
│       ├── security-group/
│       ├── cce/
│       ├── node-pool/
│       ├── iam/
│       ├── dns/
│       ├── ingress/
│       ├── nat/
│       ├── lts/
│       └── log-agent/
├── apps/                    # Apps project (Helm releases, separate state)
│   ├── backend.tf           # S3 backend + remote_state from infra
│   ├── main.tf              # Provider + locals
│   ├── variables.tf         # App versions + feature flags
│   ├── cert-manager.tf      # cert-manager + ClusterIssuer
│   ├── podinfo.tf           # Hello world app (optional)
│   ├── vault.tf             # HashiCorp Vault HA (optional)
│   ├── demo-app.tf          # Vault demo app (optional)
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── charts/
│       ├── cluster-issuer/
│       └── demo-app/
├── apps/demo-app/           # Demo app source (Dockerfile + Flask)
├── .github/workflows/
│   ├── deploy.yml           # Infra → Apps (2 jobs)
│   └── destroy.yml          # Destroy infra
└── scripts/
    └── bootstrap.sh
```

---

## Security

- Credentials via environment variables / GitHub Secrets only — never in files
- State bucket is KMS-encrypted + versioned
- CCE API is internal only by default (enable `bind_api_eip` for external kubectl access)
- Security group restricts node access to VPC CIDR + bastion CIDRs
- Destroy workflow requires typing `destroy` to confirm

## Known Issues

- **OBS + S3 backend:** OBS returns HTTP chunked transfer encoding when the AWS SDK v2 sends checksums. Fix: `skip_s3_checksum = true` in backend config (auto-set by bootstrap).
- **CCE first-time authorization:** The `cce_admin_trust` IAM agency must exist before creating a CCE cluster. The IAM module handles this. If it fails, authorize CCE manually in the T-Cloud Console (CCE → Authorize).
- **SWR image pull:** The `cce_admin_trust` agency needs `SWR Administrator` on project level (`eu-de`) so the cluster's `default-secret` can pull images from SWR. This is configured in the IAM module.
- **`AWS_SESSION_TOKEN`:** If set in your environment, OBS will reject your AK/SK with `InvalidAccessKeyId`. Unset it before running tofu.

## Troubleshooting

```bash
# Get kubeconfig (uses public IP if bind_api_eip=true)
cd infra
tofu output -raw kubeconfig > ~/.kube/config

# Check nodes
kubectl get nodes -o wide

# Deploy apps locally
cd ../apps
tofu init && tofu apply

# CCE Console
# https://console.otc.t-systems.com/cce2.0/
```
