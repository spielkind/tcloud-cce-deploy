# GPU Node Pool + GPU Demo

An optional, autoscaling GPU node pool and a text-to-image demo app that runs on it.

**URL:** `https://image.<zone>` (e.g. https://image.otc.nodefall.de) — output `gpu_demo_url`.

## Overview

```
Browser → nginx-ingress → gpu-demo pod (FastAPI + diffusers, SDXL-Turbo)
                              │  nodeSelector accelerator=nvidia
                              │  toleration nvidia.com/gpu, limit nvidia.com/gpu: 1
                              ▼
                     GPU node pool "test-gpu" (0..1 × pi5e.2xlarge.4, 1× NVIDIA L4 24 GB)
                              │  CCE AI Suite (NVIDIA GPU): device plugin + NVIDIA driver
                              ▼
                     Cluster autoscaler: adds a node when a GPU pod is pending,
                     removes it ~10 min after the last GPU pod is gone
```

| Component | Value |
|---|---|
| Node flavor | `pi5e.2xlarge.4` — 1× NVIDIA L4 (24 GB), 8 vCPU, 32 GB RAM |
| Node OS | HCE OS 2.0 (same as the default pool) |
| AZ | `eu-de-01` (`gpu_node_az`; switch to `eu-de-03` if sold out) |
| Scaling | 0 … `gpu_node_max` (default 1), CCE autoscaler addon 1.35.8 |
| Taint / label | `nvidia.com/gpu=present:NoSchedule` / `accelerator=nvidia` |
| GPU addon | CCE AI Suite (NVIDIA GPU), template `gpu-beta` 2.15.6 |
| NVIDIA driver | 580.196.07 (LTS branch, `nvidia_driver_url`; CUDA 13.x needs ≥ 580) |
| Demo image | `pytorch/pytorch:2.15.0-cuda13.2-cudnn9-runtime`, diffusers 0.43.0, FastAPI |
| Model | `stabilityai/sdxl-turbo` (`gpu_demo_model`), 1–4 steps, 512×512 |

> CCE Turbo clusters (`container_network_type = "eni"`) only support the GPU flavor families `g7`, `pi5e` and `p5e`; the variable validation enforces this.

## Enable

`infra/terraform.tfvars`:

```hcl
create_gpu_node_pool = true
```

`apps/terraform.tfvars`:

```hcl
create_gpu_demo   = true
gpu_demo_replicas = 1   # 0 = GPU node is scaled down
```

Then run **Actions → Deploy** with "Apply" and "Build Images" (the GPU image is only built when the GPU pool is enabled).

## Costs and Scale to Zero

A GPU node only exists while a GPU pod needs it:

- `gpu_demo_replicas = 1` → the pod is pending → the autoscaler creates the GPU node.
- `gpu_demo_replicas = 0` → the node becomes empty → the autoscaler removes it after ~10 minutes.

Quick toggle without a pipeline run:

```bash
kubectl scale deployment gpu-demo --replicas=0   # stop GPU node
kubectl scale deployment gpu-demo --replicas=1   # start GPU node
```

(The next Deploy resets it to `gpu_demo_replicas`.)

**Cold start:** new node (~3–5 min) + NVIDIA driver installation (~5 min) + model load. The first start downloads the model (~7 GB) into the PVC `gpu-demo-models` (`csi-disk-topology`, 30 Gi); later starts load it from disk. The PVC is bound to the AZ of the first GPU node and is kept when the release is removed (`helm.sh/resource-policy: keep`).

## The Demo App

- Prompt input with suggestions, steps (1–4) and optional seed (same seed + prompt = same image)
- Generation time, GPU name, VRAM and CUDA version, model load time
- Gallery of the last 8 images (in memory)
- Readiness only after the model is loaded; the UI is reachable before and shows "Loading model…"
- Non-root (uid 10001), read-only root filesystem, model cache on the PVC

API:

```bash
curl -s https://image.otc.nodefall.de/api/status
curl -s https://image.otc.nodefall.de/api/generate -H 'Content-Type: application/json' \
  -d '{"prompt":"a lighthouse in a storm","steps":2,"seed":7}' | jq -r .image | base64 -d > out.png
```

## Troubleshooting

```bash
kubectl get nodes -l accelerator=nvidia                         # GPU node present?
kubectl describe pod -l app=gpu-demo | tail -20                 # pending reason / scale-up events
kubectl -n kube-system get pods | grep -E 'nvidia|autoscaler'   # GPU addon + autoscaler
kubectl logs deploy/gpu-demo                                    # model download / load
```

- **Pod pending, no scale-up:** GPU capacity in the AZ may be sold out → set `gpu_node_az = "eu-de-03"`.
- **`nvidia.com/gpu` not allocatable:** the driver is still installing (~5 min after the node is ready).

## License

SDXL-Turbo is published under the Stability AI *Non-Commercial Research Community License*. That is fine for this POC; for other use cases set `gpu_demo_model` to a model with a suitable license (any `AutoPipelineForText2Image`-compatible model; adjust steps/guidance in `apps/gpu-demo/app.py` for non-turbo models).
