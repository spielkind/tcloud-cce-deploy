# Demo App

A Python web app that reads and writes secrets from Vault, demonstrating the full SWR → CCE → Vault integration.

## Architecture

![Demo App Architecture](demo-app.svg)

## What It Shows

- **Vault Agent Injector** — secrets injected as sidecar into the pod
- **SWR** — container image hosted on OTC Software Repository for Container
- **Vault API** — read + write secrets directly from the web UI
- Green dot = secrets loaded, red dot = waiting for injection

## Prerequisites

- Infra deployed (`tofu apply` in `infra/` — creates SWR organization)
- Vault initialized and unsealed (see [Vault docs](vault.md))

## Setup

### Option A: Script (recommended)

```bash
./scripts/demo-app-vault-setup.sh
```

Creates Vault policy, Kubernetes role, and seed secrets in one step.

### Option B: Manual

#### 1. Create Vault policy + role

```bash
vault policy write demo-app - <<EOF
path "kv/data/demo/*" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

vault write auth/kubernetes/role/demo-app \
  bound_service_account_names=demo-app \
  bound_service_account_namespaces=default \
  policies=demo-app \
  ttl=1h
```

#### 2. Seed secrets (optional — can also be done via web UI)

```bash
vault kv put kv/demo/config \
  message="Hello from Vault 🔐" \
  api_key="sk-demo-1234567890"
```

### Build + Deploy

The deploy workflow handles everything automatically:

1. **infra** — creates SWR organization
2. **build-images** — builds Docker image, pushes to SWR
3. **apps** — deploys Helm chart with Vault annotations

To build locally:

```bash
# Login (generate HMAC key from AK/SK)
LOGIN_KEY=$(printf "$AK" | openssl dgst -binary -sha256 -hmac "$SK" | od -An -vtx1 | sed 's/[ \n]//g' | sed 'N;s/\n//')
docker login swr.eu-de.otc.t-systems.com -u "eu-de_MIC_POC@$AK" -p "$LOGIN_KEY"

# Build + push
cd apps/demo-app
docker build -t swr.eu-de.otc.t-systems.com/mic-test/demo-app:latest .
docker push swr.eu-de.otc.t-systems.com/mic-test/demo-app:latest
```

App available at `https://demo.<zone>`.

## How It Works

```
Browser → nginx-ingress → demo-app pod
                            ├── Flask container (port 5000)
                            │   ├── reads /vault/secrets/config (injected)
                            │   └── Vault API (read + write via K8s auth)
                            └── vault-agent sidecar
                                └── fetches kv/demo/config → file
```

1. **Vault Agent Sidecar** authenticates via Kubernetes ServiceAccount JWT
2. Fetches `kv/data/demo/config` and writes to `/vault/secrets/config`
3. Flask app reads the file on each request
4. For writes, Flask authenticates directly via Vault K8s auth and calls the API
