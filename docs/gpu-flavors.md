# GPU Flavors (eu-de)

Which GPU flavors exist in region `eu-de`, whether they can be ordered, and which CCE cluster type and GPU slicing (xGPU) they support. Snapshot of the ECS flavor API from **2026-11-25** — availability changes, re-check before you plan (see [Check yourself](#check-yourself)).

## Contents

- [Summary](#summary)
- [Flavor Table](#flavor-table)
- [Notes](#notes)
- [Check yourself](#check-yourself)

## Summary

- **CCE Turbo** (`container_network_type = "eni"`, used by dev/prod): only `pi5e` (1× L4; `pi5e.8xlarge.4` with 2× L4 only in AZ 01, the 4×/6× L4 sizes are sold out) and `g7` (1× A40; 2× A40 only in AZ 03) can be ordered — neither supports xGPU. All H100 flavors are sold out.
- **GPU slicing (CCE xGPU):** T4 (`pi2`, `g6`) and V100 (`p2s`, `p2v`) are orderable — they need a **non-Turbo** cluster (`vpc-router` or `overlay_l2`). See [gpu.md → GPU Slicing](gpu.md#gpu-slicing).
- **Flavor status says nothing about deprecation:** in eu-de almost all flavors (incl. the current s9/c9/m9/x2 generations) are `abandon`; only the per-AZ status decides whether a flavor can be ordered.

## Flavor Table

Legend:

- **Availability:** 🟢 orderable · 🟡 partly sold out (orderable in one AZ, sold out in another) · 🔴 sold out
- **AZ details:** per-AZ status from `cond:operation:az` (`normal` = orderable, `sellout` = sold out); AZs not listed are not offered. The flavor-level status (`cond:operation:status`) is not shown: on OTC nearly all flavors are `abandon`, it is not a deprecation marker
- **Std / Turbo:** supported as CCE node in a Standard cluster (`vpc-router` / `overlay_l2`) or a Turbo cluster (`eni`); enforced by the `node_pools` validation
- **xGPU:** CCE GPU slicing; according to the CCE documentation only T4 and V100 are supported

| Flavor | GPU | vCPU / RAM (GB) | CPU | Availability | AZ details | Std | Turbo | xGPU |
|---|---|---|---|---|---|---|---|---|
| `pi2.2xlarge.4` | 1× T4 16 GB | 8 / 32 | Skylake 6151 3.0 GHz or Cascade Lake 6278 2.6 GHz | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `pi2.3xlarge.4` | 1× T4 16 GB | 12 / 48 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `pi2.4xlarge.4` | 2× T4 16 GB | 16 / 64 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `pi2.8xlarge.4` | 4× T4 16 GB | 32 / 128 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `g6.4xlarge.4` | 1× T4 16 GB | 16 / 64 | Cascade Lake 6266 3.0 GHz | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `g6.10xlarge.7` | 1× T4 16 GB | 40 / 280 | Cascade Lake 6266 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `g6.20xlarge.7` | 2× T4 16 GB | 80 / 560 | Cascade Lake 6266 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `p2s.2xlarge.8` | 1× V100 PCIe 32 GB | 8 / 64 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 only | ✅ | ❌ | ✅ |
| `p2s.4xlarge.8` | 2× V100 PCIe 32 GB | 16 / 128 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 only | ✅ | ❌ | ✅ |
| `p2s.8xlarge.8` | 4× V100 PCIe 32 GB | 32 / 256 | Skylake 6151 or Cascade Lake 6278 | 🟢 orderable | 01 only | ✅ | ❌ | ✅ |
| `p2s.16xlarge.8` | 8× V100 PCIe 32 GB | 64 / 512 | Skylake 6151 or Cascade Lake 6278 | 🔴 sold out | 01 sold out | ✅ | ❌ | ✅ |
| `p2v.2xlarge.8` | 1× V100 SXM2 16 GB | 8 / 64 | Skylake 6151 3.0 GHz | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `p2v.4xlarge.8` | 2× V100 SXM2 16 GB | 16 / 128 | Skylake 6151 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `p2v.8xlarge.8` | 4× V100 SXM2 16 GB | 32 / 256 | Skylake 6151 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ❌ | ✅ |
| `p2v.16xlarge.8` | 8× V100 SXM2 16 GB | 64 / 512 | Skylake 6151 | 🔴 sold out | 01 sold out, 03 sold out | ✅ | ❌ | ✅ |
| `pi5e.2xlarge.4` *(dev today)* | 1× L4 24 GB | 8 / 32 | Ice Lake 6348 2.6 GHz | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ✅ | ❌ (tested) |
| `pi5e.4xlarge.4` | 1× L4 24 GB | 16 / 64 | Ice Lake 6348 | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ✅ | ❌ |
| `pi5e.8xlarge.4` | 2× L4 24 GB | 32 / 128 | Ice Lake 6348 | 🟡 partly | 01 orderable, 03 sold out | ✅ | ✅ | ❌ |
| `pi5e.12xlarge.4` | 4× L4 24 GB | 48 / 192 | Ice Lake 6348 | 🔴 sold out | 01 sold out, 03 sold out | ✅ | ✅ | ❌ |
| `pi5e.16xlarge.4` | 4× L4 24 GB | 64 / 256 | Ice Lake 6348 | 🔴 sold out | 01 sold out, 03 sold out | ✅ | ✅ | ❌ |
| `pi5e.24xlarge.4` | 6× L4 24 GB | 96 / 384 | Ice Lake 6348 | 🔴 sold out | 01 sold out, 03 sold out | ✅ | ✅ | ❌ |
| `g7.12xlarge.8` | 1× A40 48 GB | 48 / 384 | Ice Lake 3.0 GHz | 🟢 orderable | 01 orderable, 03 orderable | ✅ | ✅ | ❌ |
| `g7.24xlarge.8` | 2× A40 48 GB | 96 / 768 | Ice Lake 3.0 GHz | 🟡 partly | 01 sold out, 03 orderable | ✅ | ✅ | ❌ |
| `g7v.2xlarge.8` | A40-8Q vGPU 8 GB | 8 / 64 | Ice Lake 3.0 GHz | 🟢 orderable | 01 only | ❓ | ❓ | ❌ |
| `g7v.4xlarge.8` | A40-16Q vGPU 16 GB | 16 / 128 | Ice Lake 3.0 GHz | 🟢 orderable | 01 only | ❓ | ❓ | ❌ |
| `g7v.6xlarge.8` | A40-24Q vGPU 24 GB | 24 / 192 | Ice Lake 3.0 GHz | 🔴 sold out | 01 sold out | ❓ | ❓ | ❌ |
| `p3.2xlarge.8` | 1× A100 80 GB | 8 / 64 | Cascade Lake 3.0 GHz | 🔴 sold out | 03 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p3.4xlarge.8` | 2× A100 80 GB | 16 / 128 | Cascade Lake 3.0 GHz | 🔴 sold out | 03 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p3.8xlarge.8` | 4× A100 80 GB | 32 / 256 | Cascade Lake 3.0 GHz | 🔴 sold out | 03 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p3.16xlarge.8` | 8× A100 80 GB | 64 / 512 | Cascade Lake 3.0 GHz | 🔴 sold out | 03 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p5s.5xlarge.12` | 1× H100 PCIe 80 GB | 20 / 240 | Xeon Platinum 8458P 2.7 GHz | 🔴 sold out | 01 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p5s.10xlarge.12` / `20xlarge` / `40xlarge` | 2× / 4× / 8× H100 PCIe 80 GB | 40 / 480 … 160 / 1920 | Xeon Platinum 8458P | 🔴 sold out | 01 sold out | ✅ | ❌ | ❌ (MIG capable\*) |
| `p5e.10xlarge.12` | 2× H100 NVL 94 GB | 40 / 480 | Xeon Platinum 8458P | 🔴 sold out | 01 sold out | ✅ | ✅ | ❌ (MIG capable\*) |
| `p5e.20xlarge.12` | 4× H100 NVL 94 GB | 80 / 960 | Xeon Platinum 8458P | 🔴 sold out | 01 sold out | ✅ | ✅ | ❌ (MIG capable\*) |
| `p5e.40xlarge.12` | 8× H100 NVL 80 GB | 160 / 1920 | Xeon Platinum 8458P | 🔴 sold out | 01 sold out | ✅ | ✅ | ❌ (MIG capable\*) |
| `g2.2xlarge` | M60 (graphics) | 8 / 64 | – | 🔴 sold out | 01 sold out, 02 sold out | ❌ | ❌ | ❌ |

\* A100 and H100 support MIG in hardware, but the CCE AI Suite addon (2.15.6) has no MIG parameter — and the flavors are sold out anyway.

## Notes

- **xGPU on the L4** was tested in dev: the device plugin reports `current gpu name is not supported, use legacy shared mode`, so `gpu_xgpu = false` in dev.
- **`g7v`** (NVIDIA GRID vGPU): CCE node support not verified; the `node_pools` validation does not allow it.
- **`p2s.16xlarge.8` / `p2v.16xlarge.8`:** ✅ in *Std* only means the flavor family is allowed; the exact sizes were not verified in CCE.
- **CPU** is the value of `info:cpu:name`; "Skylake or Cascade Lake" means the flavor can land on either host type.
- **Switching to a non-Turbo cluster** (for T4/V100) means a new cluster — the network type cannot be changed. Consequences are listed in [gpu.md → GPU Slicing](gpu.md#gpu-slicing).

## Check yourself

ECS flavor API (`GET /v1/{project_id}/cloudservers/flavors`), relevant `os_extra_specs`:

| Field | Meaning |
|---|---|
| `info:gpu:name` / `pci_passthrough:alias` | GPU model and count |
| `info:cpu:name` | CPU type |
| `cond:operation:status` | flavor status (`normal`, `abandon`, `sellout`); default for AZs not listed in `cond:operation:az`, not a deprecation marker on OTC |
| `cond:operation:az` | per-AZ status, e.g. `eu-de-01(normal),eu-de-03(sellout)`; overrides the flavor status |
