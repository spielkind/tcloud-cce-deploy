"""GPU AI playground: text→image, image→image, chat, speech→text, vision and a GPU panel on one GPU.

Heavy libraries (torch, diffusers, transformers, pynvml) are imported lazily inside loader/job functions so the
server starts without them (STUB_MODELS=1 or CPU-only test environments).
"""
import base64
import gc
import io
import json
import math
import os
import queue
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from PIL import Image, ImageDraw, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, Field


def env_bool(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes", "on")


VERSION = os.environ.get("APP_VERSION", "dev")
MODEL_ID = os.environ.get("MODEL_ID", "stabilityai/sdxl-turbo")
CHAT_MODEL = os.environ.get("CHAT_MODEL", "Qwen/Qwen2.5-3B-Instruct")
STT_MODEL = os.environ.get("STT_MODEL", "openai/whisper-large-v3-turbo")
VISION_MODEL = os.environ.get("VISION_MODEL", "florence-community/Florence-2-base")
# Florence-2 remote code is executed (trust_remote_code); pin a commit SHA here for reproducible deployments.
VISION_MODEL_REVISION = os.environ.get("VISION_MODEL_REVISION", "main")
# Native transformers port, used when the remote code of VISION_MODEL cannot load with the installed transformers.
_default_fallback = (
    "florence-community/" + VISION_MODEL.split("/", 1)[1] if VISION_MODEL.startswith("microsoft/Florence-2-") else ""
)
VISION_FALLBACK_MODEL = os.environ.get("VISION_FALLBACK_MODEL", _default_fallback)
DEVICE = os.environ.get("DEVICE", "cuda")
IMAGE_SIZE = int(os.environ.get("IMAGE_SIZE", "512"))
STUB = env_bool("STUB_MODELS")
PRELOAD = [n.strip() for n in os.environ.get("PRELOAD", "image").split(",") if n.strip()]
HF_TOKEN_FILE = os.environ.get("HF_TOKEN_FILE", "/vault/secrets/hf")
TMP_DIR = os.environ.get("TMPDIR") or tempfile.gettempdir()

GALLERY_SIZE = 8
MB = 1024 * 1024
MAX_REQUEST_BYTES = 30 * MB
MAX_IMAGE_BYTES = 10 * MB
MAX_AUDIO_BYTES = 25 * MB
MAX_AUDIO_SECONDS = 300
CHAT_MAX_INPUT_TOKENS = int(os.environ.get("CHAT_MAX_INPUT_TOKENS", "6144"))
IMG2IMG_SIZE = 512
VISION_MAX_SIDE = 1536
Image.MAX_IMAGE_PIXELS = 50_000_000  # decompression bomb guard


def _gb_env(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


# Rough VRAM needs (weights + working memory) used for the eviction budget.
VRAM_ESTIMATES_GB = {
    "image": _gb_env("IMAGE_VRAM_GB", 9.0),
    "chat": _gb_env("CHAT_VRAM_GB", 7.0),
    "stt": _gb_env("STT_VRAM_GB", 2.0),
    "vision": _gb_env("VISION_VRAM_GB", 1.5),
}

# GPU slicing (CCE xGPU): MODE=slice-worker runs a model-free pod that only shows and exercises its slice.
WORKER = os.environ.get("MODE", "playground") == "slice-worker"
if WORKER:
    PRELOAD = []
SLICE_NAME = os.environ.get("SLICE_NAME", "")
SLICE_MEM_GIB = _gb_env("SLICE_MEM_GIB", 0)
SLICE_CORE_PERCENT = _gb_env("SLICE_CORE_PERCENT", 0)
VRAM_LIMIT_GB = _gb_env("VRAM_LIMIT_GB", 0)  # model manager budget inside the slice (0 = whole GPU)
CARD_MEM_GIB = _gb_env("CARD_MEM_GIB", 22)  # usable VRAM of one L4, used to draw the slicing bars


def _slice_workers():
    try:
        items = json.loads(os.environ.get("SLICE_WORKERS", "[]") or "[]")
    except ValueError:
        return []
    return [w for w in items if isinstance(w, dict) and w.get("name") and w.get("url")]


SLICE_WORKERS = _slice_workers()

gallery = deque(maxlen=GALLERY_SIZE)
gpu_lock = threading.Lock()
gpu_job = {"name": None, "since": None}
runtime = {"gpu": None}


# --------------------------------------------------------------------------------------------- HF token
_hf = {"source": None}
_hf_lock = threading.Lock()


def refresh_hf_token() -> str | None:
    """Return the token source ("env"/"file") or None. The OpenBao sidecar may render the file late, so this is
    re-read before every model load and on every GPU panel poll. The token value is never returned."""
    with _hf_lock:
        if _hf["source"] != "file" and os.environ.get("HF_TOKEN", "").strip():
            _hf["source"] = "env"
            return "env"
        token = ""
        try:
            with open(HF_TOKEN_FILE, encoding="utf-8") as f:
                raw = f.read(8192).strip()
        except OSError:
            raw = ""
        if raw:
            try:
                data = json.loads(raw)
                if isinstance(data, dict):
                    token = data.get("token") or data.get("HF_TOKEN") or ""
                    if not token and isinstance(data.get("data"), dict):
                        token = data["data"].get("token", "")
            except ValueError:
                token = raw
        token = str(token).strip()
        if token and not any(c.isspace() for c in token):
            os.environ["HF_TOKEN"] = token
            _hf["source"] = "file"
        elif _hf["source"] == "file":
            os.environ.pop("HF_TOKEN", None)  # file was removed / emptied
            _hf["source"] = None
        return _hf["source"]


# --------------------------------------------------------------------------------------------- torch helpers
def cuda_ok() -> bool:
    if STUB or DEVICE != "cuda":
        return False
    try:
        import torch
    except ImportError:
        return False
    return torch.cuda.is_available()


def run_device() -> str:
    return "cuda" if cuda_ok() else "cpu"


def cuda_allocated() -> int:
    if not cuda_ok():
        return 0
    import torch

    return torch.cuda.memory_allocated()


def cuda_free() -> tuple[int, int] | None:
    if not cuda_ok():
        return None
    import torch

    return torch.cuda.mem_get_info()


def budget_free() -> int | None:
    """Free VRAM for the model manager; with VRAM_LIMIT_GB the budget stays inside the xGPU slice even if the
    driver reports more."""
    mem = cuda_free()
    if mem is None:
        return None
    free = mem[0]
    if VRAM_LIMIT_GB > 0:
        import torch

        free = min(free, int(VRAM_LIMIT_GB * 2**30) - torch.cuda.memory_reserved())
    return max(0, free)


def release_memory():
    gc.collect()
    if "torch" in sys.modules and cuda_ok():
        import torch

        torch.cuda.empty_cache()


def gpu_info():
    if STUB:
        return {"name": "stub (no GPU)", "memory_gb": None, "cuda": None}
    import torch

    if not cuda_ok():
        return {"name": "CPU", "memory_gb": None, "cuda": None}
    props = torch.cuda.get_device_properties(0)
    return {"name": props.name, "memory_gb": round(props.total_memory / 2**30, 1), "cuda": torch.version.cuda}


def err_text(e: Exception, limit: int = 800) -> str:
    return f"{type(e).__name__}: {e}"[:limit]


# --------------------------------------------------------------------------------------------- model manager
class Slot:
    def __init__(self, name, title, model_id, loader, keep=False):
        self.name, self.title, self.model_id, self.loader, self.keep = name, title, model_id, loader, keep
        self.est_gb = VRAM_ESTIMATES_GB[name]
        self.status = "not_loaded"
        self.error = None
        self.progress = ""
        self.note = ""
        self.obj = None
        self.extra = {}
        self.load_seconds = None
        self.vram_gb = None
        self.loaded_at = None
        self.last_used = None
        self.in_use = 0
        self.device = None
        self.settled = False  # reached ready/error at least once (used by /readyz for preloaded models)

    def info(self):
        return {"name": self.name, "title": self.title, "model_id": self.model_id, "status": self.status,
                "error": self.error, "progress": self.progress, "note": self.note, "est_gb": self.est_gb,
                "vram_gb": self.vram_gb, "load_seconds": self.load_seconds, "loaded_at": self.loaded_at,
                "last_used": self.last_used, "in_use": self.in_use > 0, "device": self.device,
                "variant": self.extra.get("variant")}


class ModelManager:
    def __init__(self):
        self.slots: dict[str, Slot] = {}
        self.lock = threading.RLock()
        self.load_lock = threading.Lock()  # one load at a time

    def register(self, slot: Slot):
        self.slots[slot.name] = slot

    def get(self, name: str) -> Slot:
        slot = self.slots.get(name)
        if slot is None:
            raise HTTPException(404, f"Unknown model '{name}'")
        return slot

    def request_load(self, name: str) -> str:
        if WORKER:
            raise HTTPException(404, "Slice workers do not load models")
        slot = self.get(name)
        with self.lock:
            if slot.status in ("not_loaded", "error"):
                slot.status, slot.error, slot.note, slot.progress = "loading", None, "", "queued"
                threading.Thread(target=self._load, args=(slot,), daemon=True, name=f"load-{name}").start()
            return slot.status

    def _load(self, slot: Slot):
        with self.load_lock:
            start = time.monotonic()
            try:
                refresh_hf_token()
                slot.progress = "checking VRAM budget"
                self._make_room(slot)
                before = cuda_allocated()
                slot.progress = "loading weights (first start downloads to HF_HOME)"
                obj = slot.loader(slot)
                after = cuda_allocated()
                with self.lock:
                    slot.obj = obj
                    slot.device = "stub" if STUB else run_device()
                    slot.vram_gb = round((after - before) / 2**30, 2) if cuda_ok() else None
                    slot.load_seconds = round(time.monotonic() - start, 1)
                    slot.loaded_at = slot.last_used = time.time()
                    slot.status = "ready"
                if runtime["gpu"] is None:
                    runtime["gpu"] = gpu_info()
            except Exception as e:  # noqa: BLE001 - surface any load error in the UI
                slot.obj = None
                slot.extra.clear()
                slot.error = err_text(e)
                slot.status = "error"
                release_memory()
            finally:
                slot.progress = ""
                slot.settled = True

    def _make_room(self, slot: Slot):
        need = slot.est_gb * 2**30
        while True:
            free = budget_free()
            if free is None or free >= need:
                return
            with self.lock:
                candidates = [s for s in self.slots.values()
                              if s is not slot and s.status == "ready" and s.in_use == 0]
                if not candidates:
                    slot.progress = f"only {free / 2**30:.1f} GB free, nothing to evict – loading anyway"
                    return
                victim = min(candidates, key=lambda s: (s.keep, s.last_used or 0))
                slot.progress = f"unloading '{victim.name}' to free VRAM"
                self._unload_locked(victim, f"evicted to make room for '{slot.name}'")

    def _unload_locked(self, slot: Slot, note: str):
        slot.obj = None
        slot.extra.clear()
        slot.status, slot.vram_gb, slot.device, slot.note = "not_loaded", None, None, note
        release_memory()

    def unload(self, name: str):
        slot = self.get(name)
        with self.lock:
            if slot.status == "loading":
                raise HTTPException(409, f"Model '{name}' is loading, unload it afterwards")
            if slot.in_use:
                raise HTTPException(409, f"Model '{name}' is running a job right now")
            if slot.status == "ready":
                self._unload_locked(slot, "unloaded manually")
            elif slot.status == "error":
                slot.status, slot.error = "not_loaded", None
            return slot.info()

    def ensure_ready(self, name: str) -> Slot:
        slot = self.get(name)
        with self.lock:
            if slot.status == "ready":
                return slot
        status = self.request_load(name)
        if status == "ready":
            return slot
        raise HTTPException(409, f"Model '{name}' is loading – try again when its badge shows ready")

    def acquire(self, name: str) -> Slot:
        slot = self.ensure_ready(name)
        with self.lock:
            if slot.status != "ready":
                raise HTTPException(409, f"Model '{name}' is not loaded")
            slot.in_use += 1
            slot.last_used = time.time()
        return slot

    def release(self, slot: Slot):
        with self.lock:
            slot.in_use = max(0, slot.in_use - 1)
            slot.last_used = time.time()


models = ModelManager()


def begin_job(model: str | None, job: str) -> Slot | None:
    slot = models.acquire(model) if model else None
    if not gpu_lock.acquire(blocking=False):
        if slot:
            models.release(slot)
        raise HTTPException(429, "GPU busy")
    gpu_job.update(name=job, since=time.time())
    return slot


def end_job(slot: Slot | None):
    gpu_job.update(name=None, since=None)
    if slot:
        models.release(slot)
    gpu_lock.release()


def run_job(model: str, job: str, fn):
    slot = begin_job(model, job)
    try:
        return fn(slot)
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        release_memory()
        raise HTTPException(500, err_text(e)) from e
    finally:
        end_job(slot)


# --------------------------------------------------------------------------------------------- loaders
def _dtype_for(dev: str, prefer_bf16: bool = False):
    import torch

    if dev != "cuda":
        return torch.float32
    if prefer_bf16 and torch.cuda.is_bf16_supported():
        return torch.bfloat16
    return torch.float16


def load_image_model(slot: Slot):
    if STUB:
        time.sleep(0.05)
        return {"stub": True}
    from diffusers import AutoPipelineForText2Image

    dev = run_device()
    kwargs = {"dtype": _dtype_for(dev)}  # diffusers >= 0.43: torch_dtype is deprecated
    if dev == "cuda":
        kwargs["variant"] = "fp16"
    pipe = AutoPipelineForText2Image.from_pretrained(MODEL_ID, **kwargs)
    slot.progress = f"moving pipeline to {dev}"
    pipe = pipe.to(dev)
    pipe.set_progress_bar_config(disable=True)
    return pipe


def img2img_pipe(slot: Slot):
    if "img2img" not in slot.extra:
        from diffusers import AutoPipelineForImage2Image

        pipe = AutoPipelineForImage2Image.from_pipe(slot.obj)  # shares all components: no extra VRAM
        pipe.set_progress_bar_config(disable=True)
        slot.extra["img2img"] = pipe
    return slot.extra["img2img"]


def load_chat_model(slot: Slot):
    if STUB:
        time.sleep(0.05)
        return {"stub": True}
    from transformers import AutoModelForCausalLM, AutoTokenizer

    dev = run_device()
    tokenizer = AutoTokenizer.from_pretrained(CHAT_MODEL)
    kwargs = {"dtype": _dtype_for(dev, prefer_bf16=True)}
    if dev == "cuda":
        kwargs["device_map"] = "cuda"
    model = AutoModelForCausalLM.from_pretrained(CHAT_MODEL, **kwargs)
    if dev != "cuda":
        model.to(dev)
    model.eval()
    return {"model": model, "tokenizer": tokenizer, "device": dev}


def load_stt_model(slot: Slot):
    if STUB:
        time.sleep(0.05)
        return {"stub": True}
    from transformers import pipeline

    dev = run_device()
    return pipeline("automatic-speech-recognition", model=STT_MODEL, dtype=_dtype_for(dev), device=dev)


def load_vision_model(slot: Slot):
    if STUB:
        time.sleep(0.05)
        slot.extra["variant"] = "stub"
        return {"stub": True}
    import transformers
    from transformers import AutoModelForCausalLM, AutoProcessor

    dev = run_device()
    dtype = _dtype_for(dev)

    def remote(model_id, revision):
        from unittest.mock import patch

        from transformers import dynamic_module_utils as dmu

        orig = dmu.get_imports

        def imports_without_flash_attn(filename):  # Florence-2 remote code lists flash_attn as a hard import
            return [i for i in orig(filename) if i != "flash_attn"]

        with patch.object(dmu, "get_imports", imports_without_flash_attn):
            model = AutoModelForCausalLM.from_pretrained(model_id, revision=revision, trust_remote_code=True,
                                                         dtype=dtype, attn_implementation="eager")
            processor = AutoProcessor.from_pretrained(model_id, revision=revision, trust_remote_code=True)
        return model, processor

    def native(model_id, revision):
        cls = getattr(transformers, "Florence2ForConditionalGeneration", None)
        if cls is None:
            raise RuntimeError(f"transformers {transformers.__version__} has no native Florence2 support")
        return cls.from_pretrained(model_id, revision=revision, dtype=dtype), AutoProcessor.from_pretrained(
            model_id, revision=revision)

    if VISION_MODEL.startswith("microsoft/"):
        attempts = [("remote-code", remote, VISION_MODEL, VISION_MODEL_REVISION)]
        if VISION_FALLBACK_MODEL:
            attempts.append(("native", native, VISION_FALLBACK_MODEL, "main"))
    else:
        # Native transformers models only: remote code is executed solely for explicitly chosen microsoft/* repos.
        attempts = [("native", native, VISION_MODEL, VISION_MODEL_REVISION)]
    errors = []
    for kind, fn, model_id, revision in attempts:
        slot.progress = f"loading {model_id}@{revision} ({kind})"
        try:
            model, processor = fn(model_id, revision)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{kind} {model_id}: {err_text(e, 400)}")
            release_memory()
            continue
        model.to(dev).eval()
        slot.extra["variant"] = f"{kind} {model_id}@{revision}"
        return {"model": model, "processor": processor, "device": dev, "dtype": dtype, "kind": kind}
    raise RuntimeError(" | ".join(errors))


models.register(Slot("image", "SDXL-Turbo", MODEL_ID, load_image_model, keep=True))
models.register(Slot("chat", "Chat LLM", CHAT_MODEL, load_chat_model))
models.register(Slot("stt", "Whisper", STT_MODEL, load_stt_model))
models.register(Slot("vision", "Florence-2", f"{VISION_MODEL}@{VISION_MODEL_REVISION}", load_vision_model))


# --------------------------------------------------------------------------------------------- helpers
def png_b64(img: Image.Image) -> str:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def fake_image(text: str, seed: int, size: int, base: Image.Image | None = None, strength: float = 1.0):
    rnd = random.Random(seed)
    c1, c2 = (tuple(rnd.randint(0, 255) for _ in range(3)) for _ in range(2))
    mask = Image.linear_gradient("L").resize((size, size))
    img = Image.composite(Image.new("RGB", (size, size), c1), Image.new("RGB", (size, size), c2), mask)
    if base is not None:
        img = Image.blend(base.convert("RGB").resize((size, size)), img, min(1.0, strength) * 0.8)
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, size - 36, size, size), fill=(0, 0, 0))
    draw.text((10, size - 26), ("STUB · " + text)[:70], fill=(255, 255, 255))
    return img


def read_upload(upload: UploadFile, kind: str, limit: int) -> tuple[bytes, str]:
    ctype = (upload.content_type or "").split(";")[0].strip().lower()
    if not ctype.startswith(kind + "/"):
        raise HTTPException(415, f"Expected an {kind}/* file, got '{ctype or 'unknown'}'")
    data = upload.file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(413, f"File too large (max {limit // MB} MB)")
    if not data:
        raise HTTPException(400, "Empty file")
    return data, ctype


def open_image(data: bytes) -> Image.Image:
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
        img = ImageOps.exif_transpose(img)
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError) as e:
        raise HTTPException(400, f"Cannot read image: {type(e).__name__}") from e
    return img.convert("RGB")


def new_seed(seed: int | None) -> int:
    return seed if seed is not None else random.randint(0, 2**31 - 1)


def torch_generator(seed: int):
    import torch

    return torch.Generator(device=run_device()).manual_seed(seed)


# --------------------------------------------------------------------------------------------- audio decoding
def _read_audio_file(path: str):
    """Return (samples float32 [n] or [n, ch], sample_rate) using soundfile, falling back to the wave module."""
    import numpy as np

    try:
        import soundfile as sf

        data, sr = sf.read(path, dtype="float32", always_2d=False)
        return np.asarray(data, dtype=np.float32), int(sr)
    except ImportError:
        pass
    with wave.open(path, "rb") as w:
        sr, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(min(n, sr * (MAX_AUDIO_SECONDS + 1)))
    if width == 1:
        arr = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128) / 128
    elif width == 2:
        arr = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768
    elif width == 4:
        arr = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648
    else:
        raise ValueError(f"unsupported WAV sample width {width}")
    return (arr.reshape(-1, ch) if ch > 1 else arr), sr


def decode_audio(data: bytes, ctype: str):
    """Decode uploaded audio to 16 kHz mono float32. Uses soundfile for wav/flac, ffmpeg for webm/ogg/mp3/m4a."""
    import numpy as np

    sub = ctype.split("/", 1)[1] if "/" in ctype else ""
    fd, src = tempfile.mkstemp(prefix="stt-in-", suffix=".audio", dir=TMP_DIR)
    out = src + ".wav"
    errors = []
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        audio = None
        if sub in ("wav", "x-wav", "wave", "vnd.wave", "flac", "x-flac"):
            try:
                audio = _read_audio_file(src)
            except Exception as e:  # noqa: BLE001
                errors.append(f"soundfile: {err_text(e, 200)}")
        ffmpeg = shutil.which("ffmpeg")
        if audio is None and ffmpeg:
            cmd = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                   "-t", str(MAX_AUDIO_SECONDS + 1), "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", out]
            try:
                proc = subprocess.run(cmd, capture_output=True, timeout=120, check=False)
                if proc.returncode == 0:
                    audio = _read_audio_file(out)
                else:
                    errors.append("ffmpeg: " + proc.stderr.decode(errors="replace").strip()[-300:])
            except subprocess.TimeoutExpired:
                errors.append("ffmpeg: timeout")
        elif audio is None:
            errors.append("ffmpeg not installed")
        if audio is None:
            try:
                audio = _read_audio_file(src)
            except Exception as e:  # noqa: BLE001
                errors.append(f"fallback: {err_text(e, 200)}")
        if audio is None:
            raise HTTPException(400, "Could not decode audio – " + "; ".join(errors))
    finally:
        for p in (src, out):
            try:
                os.remove(p)
            except OSError:
                pass
    samples, sr = audio
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if sr != 16000 and len(samples):
        n = int(round(len(samples) * 16000 / sr))
        samples = np.interp(np.linspace(0, len(samples) - 1, n), np.arange(len(samples)), samples)
    return np.ascontiguousarray(samples, dtype=np.float32)


# --------------------------------------------------------------------------------------------- GPU stats
_nvml = {"mod": None, "error": None}
_nvml_lock = threading.Lock()


def nvml():
    with _nvml_lock:
        if _nvml["mod"] is not None or _nvml["error"] is not None:
            return _nvml["mod"]
        try:
            import pynvml

            pynvml.nvmlInit()
            _nvml["mod"] = pynvml
        except ImportError:
            _nvml["error"] = "nvidia-ml-py not installed"
        except Exception as e:  # noqa: BLE001
            _nvml["error"] = err_text(e, 200)
        return _nvml["mod"]


def _safe(fn, *args):
    try:
        return fn(*args)
    except Exception:  # noqa: BLE001
        return None


def gpu_stats():
    nv = nvml()
    gpus = []
    if nv is not None:
        for i in range(_safe(nv.nvmlDeviceGetCount) or 0):
            h = nv.nvmlDeviceGetHandleByIndex(i)
            name = _safe(nv.nvmlDeviceGetName, h)
            util = _safe(nv.nvmlDeviceGetUtilizationRates, h)
            mem = _safe(nv.nvmlDeviceGetMemoryInfo, h)
            power = _safe(nv.nvmlDeviceGetPowerUsage, h)
            limit = _safe(nv.nvmlDeviceGetEnforcedPowerLimit, h)
            gpus.append({
                "index": i,
                "name": name.decode() if isinstance(name, bytes) else name,
                "util_pct": util.gpu if util else None,
                "mem_util_pct": util.memory if util else None,
                "vram_used_gb": round(mem.used / 2**30, 2) if mem else None,
                "vram_total_gb": round(mem.total / 2**30, 2) if mem else None,
                "temp_c": _safe(nv.nvmlDeviceGetTemperature, h, nv.NVML_TEMPERATURE_GPU),
                "power_w": round(power / 1000, 1) if power is not None else None,
                "power_limit_w": round(limit / 1000, 1) if limit is not None else None,
                "sm_clock_mhz": _safe(nv.nvmlDeviceGetClockInfo, h, nv.NVML_CLOCK_SM),
                "sm_clock_max_mhz": _safe(nv.nvmlDeviceGetMaxClockInfo, h, nv.NVML_CLOCK_SM),
                "mem_clock_mhz": _safe(nv.nvmlDeviceGetClockInfo, h, nv.NVML_CLOCK_MEM),
            })
    driver = _safe(nv.nvmlSystemGetDriverVersion) if nv is not None else None
    torch_mem = None
    if "torch" in sys.modules and cuda_ok():
        import torch

        torch_mem = {"allocated_gb": round(torch.cuda.memory_allocated() / 2**30, 2),
                     "reserved_gb": round(torch.cuda.memory_reserved() / 2**30, 2)}
    reason = None if gpus else (_nvml["error"] or "no NVIDIA GPU")
    return {"available": bool(gpus), "reason": reason, "gpus": gpus,
            "driver": driver.decode() if isinstance(driver, bytes) else driver, "torch": torch_mem}


def run_benchmark(n: int = 2048):
    flop = 2 * n**3
    try:
        import torch
    except ImportError:
        torch = None
    if torch is not None and not STUB:
        a, b = torch.randn(n, n), torch.randn(n, n)
        cpu_fn, backend, threads = (lambda: a @ b), "torch", torch.get_num_threads()
    else:
        import numpy as np

        rng = np.random.default_rng(0)
        a, b = rng.standard_normal((n, n), dtype=np.float32), rng.standard_normal((n, n), dtype=np.float32)
        cpu_fn, backend, threads = (lambda: a @ b), "numpy", os.cpu_count()
    total, reps, t0 = 0.0, 0, time.perf_counter()
    while reps < 5:  # bounded: stops after ~3.5 s even on a slow / throttled CPU
        s = time.perf_counter()
        cpu_fn()
        dt = time.perf_counter() - s
        total += dt
        reps += 1
        if time.perf_counter() - t0 + dt > 3.5:
            break
    cpu = {"backend": backend, "threads": threads, "reps": reps, "ms_per_matmul": round(total / reps * 1000, 2),
           "gflops": round(flop / (total / reps) / 1e9, 1)}
    cpu_fn = a = b = None
    result = {"size": n, "cpu": cpu, "gpu": {"available": False}}
    if torch is not None and cuda_ok():
        gpu = {"available": True, "name": torch.cuda.get_device_name(0)}
        for label, dtype in (("fp32", torch.float32), ("fp16", torch.float16)):
            x = torch.randn(n, n, device="cuda", dtype=dtype)
            y = torch.randn(n, n, device="cuda", dtype=dtype)
            for _ in range(3):
                x @ y
            torch.cuda.synchronize()
            reps = 20
            s = time.perf_counter()
            for _ in range(reps):
                x @ y
            torch.cuda.synchronize()
            dt = (time.perf_counter() - s) / reps
            gpu[label] = {"reps": reps, "ms_per_matmul": round(dt * 1000, 3), "gflops": round(flop / dt / 1e9, 1)}
            del x, y
        torch.cuda.empty_cache()
        gpu["speedup_fp32"] = round(gpu["fp32"]["gflops"] / max(cpu["gflops"], 1e-9), 1)
        gpu["speedup_fp16"] = round(gpu["fp16"]["gflops"] / max(cpu["gflops"], 1e-9), 1)
        result["gpu"] = gpu
    else:
        result["gpu"]["reason"] = "stub mode" if STUB else ("torch not installed" if torch is None else "no CUDA GPU")
    return result


# --------------------------------------------------------------------------------------------- GPU slicing
_slice = {"last_bench": None, "last_oom": None}
slice_lock = threading.Lock()  # one benchmark / OOM test per worker at a time
SLICE_BENCH_SECONDS = 6.0
STUB_L4_TFLOPS = 60.0


def slice_self() -> dict:
    info = {"name": SLICE_NAME or ("worker" if WORKER else "playground"), "role": "worker" if WORKER else "playground",
            "pod": os.environ.get("HOSTNAME"), "node": os.environ.get("NODE_NAME"),
            "mem_gib": SLICE_MEM_GIB or None, "core_percent": SLICE_CORE_PERCENT or None, "stub": STUB,
            "version": VERSION, "busy": slice_lock.locked() if WORKER else gpu_job["name"],
            "last_bench": _slice["last_bench"], "last_oom": _slice["last_oom"], "seen": None, "nvml": None}
    if STUB:
        total = SLICE_MEM_GIB or CARD_MEM_GIB
        info["seen"] = {"device": "stub", "total_gb": total, "free_gb": round(total * 0.9, 2), "process_reserved_gb": 0}
    elif cuda_ok():
        import torch

        free, total = torch.cuda.mem_get_info()  # under xGPU this reports the slice, not the whole card
        info["seen"] = {"device": torch.cuda.get_device_name(0), "total_gb": round(total / 2**30, 2),
                        "free_gb": round(free / 2**30, 2), "process_reserved_gb": round(torch.cuda.memory_reserved() / 2**30, 2)}
    g = gpu_stats()["gpus"]
    if g:
        info["nvml"] = {k: g[0][k] for k in ("name", "util_pct", "vram_used_gb", "vram_total_gb")}
    return info


def slice_bench(seconds: float = SLICE_BENCH_SECONDS, n: int = 4096) -> dict:
    """fp16 matmul throughput for a few seconds; with xGPU compute limits it follows core_percent."""
    flop = 2 * n**3
    if STUB:
        time.sleep(1.0)
        share = (SLICE_CORE_PERCENT or 100) / 100
        tflops = STUB_L4_TFLOPS * share * random.uniform(0.92, 1.0)
        result = {"tflops": round(tflops, 2), "reps": int(tflops * 1e12 * seconds / flop), "seconds": seconds}
    else:
        if not cuda_ok():
            raise HTTPException(503, "No CUDA GPU visible in this pod")
        import torch

        x = torch.randn(n, n, device="cuda", dtype=torch.float16)
        y = torch.randn(n, n, device="cuda", dtype=torch.float16)
        for _ in range(3):
            x @ y
        torch.cuda.synchronize()
        reps, start = 0, time.perf_counter()
        while time.perf_counter() - start < seconds:
            for _ in range(5):
                x @ y
            torch.cuda.synchronize()
            reps += 5
        elapsed = time.perf_counter() - start
        del x, y
        torch.cuda.empty_cache()
        result = {"tflops": round(flop * reps / elapsed / 1e12, 2), "reps": reps, "seconds": round(elapsed, 2)}
    result.update(n=n, dtype="fp16", at=time.time(), core_percent=SLICE_CORE_PERCENT or None)
    _slice["last_bench"] = result
    return result


def slice_oom(step_mb: int = 256) -> dict:
    """Allocate VRAM in steps until the driver refuses. Stops 1 GiB above the slice, so a missing limit cannot
    starve the other pods for long."""
    configured = SLICE_MEM_GIB or None
    cap_gb = (configured or CARD_MEM_GIB) + 1
    if STUB:
        time.sleep(0.5)
        allocated, hit, driver_error = (configured or CARD_MEM_GIB) - 0.5, True, "stub: CUDA out of memory"
    else:
        if not cuda_ok():
            raise HTTPException(503, "No CUDA GPU visible in this pod")
        import torch

        blocks, hit, driver_error = [], False, None
        try:
            while len(blocks) * step_mb / 1024 < cap_gb:
                blocks.append(torch.empty(step_mb * MB, dtype=torch.uint8, device="cuda"))
        except (torch.OutOfMemoryError, RuntimeError) as e:  # xGPU may surface as a generic CUDA error
            hit, driver_error = True, err_text(e, 240)
        allocated = len(blocks) * step_mb / 1024
        blocks.clear()
        torch.cuda.empty_cache()
    result = {"allocated_gb": round(allocated, 2), "configured_gb": configured, "limit_hit": hit, "cap_gb": cap_gb,
              "driver_error": driver_error, "at": time.time(),
              "isolated": bool(hit and configured and allocated <= configured + 0.25)}
    _slice["last_oom"] = result
    return result


def _peer(method: str, url: str, timeout: float):
    req = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - in-cluster service URLs from config
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read()).get("detail")
        except ValueError:
            detail = None
        return {"error": detail or f"HTTP {e.code}"}
    except Exception as e:  # noqa: BLE001 - unreachable / not ready yet
        return {"error": err_text(e, 200)}


def _worker(name: str) -> dict:
    for w in SLICE_WORKERS:
        if w["name"] == name:
            return w
    raise HTTPException(404, f"Unknown slice worker '{name}'")


# --------------------------------------------------------------------------------------------- app
class BodyLimit:
    """Reject oversized request bodies early (pure ASGI, so streaming responses are unaffected)."""

    def __init__(self, app, limit: int):
        self.app, self.limit = app, limit

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["method"] in ("POST", "PUT", "PATCH"):
            headers = dict(scope["headers"])
            length = headers.get(b"content-length")
            if length is None and b"chunked" in headers.get(b"transfer-encoding", b""):
                await JSONResponse({"detail": "Content-Length required"}, 411)(scope, receive, send)
                return
            if length is not None and (not length.isdigit() or int(length) > self.limit):
                await JSONResponse({"detail": f"Request too large (max {self.limit // MB} MB)"}, 413)(
                    scope, receive, send)
                return
        await self.app(scope, receive, send)


@asynccontextmanager
async def lifespan(_app):
    refresh_hf_token()
    for name in PRELOAD:
        if name in models.slots:
            models.request_load(name)
    yield


app = FastAPI(title="GPU AI Playground", lifespan=lifespan)
app.add_middleware(BodyLimit, limit=MAX_REQUEST_BYTES)


class GenerateRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=300)
    steps: int = Field(default=2, ge=1, le=4)
    seed: int | None = Field(default=None, ge=0, le=2**31 - 1)


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=8000)


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1, max_length=64)
    max_new_tokens: int = Field(default=256, ge=1, le=512)
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/readyz")
def readyz():
    pending = [n for n in PRELOAD if n in models.slots and not models.slots[n].settled]
    if pending:
        return JSONResponse({"status": "loading", "pending": pending}, status_code=503)
    return {"status": "ready"}


@app.get("/api/status")
def status():
    img = models.slots["image"]
    if runtime["gpu"] is None and STUB:
        runtime["gpu"] = gpu_info()
    return {"status": img.status, "error": img.error, "model": MODEL_ID, "gpu": runtime["gpu"],
            "load_seconds": img.load_seconds, "version": VERSION, "size": IMAGE_SIZE, "stub": STUB,
            "busy": gpu_job["name"], "models": {n: s.info() for n, s in models.slots.items()}}


@app.get("/api/gallery")
def get_gallery():
    return list(gallery)


@app.post("/api/generate")
def generate(req: GenerateRequest):
    seed = new_seed(req.seed)

    def job(slot):
        start = time.monotonic()
        if STUB:
            image = fake_image(req.prompt, seed, IMAGE_SIZE)
        else:
            image = slot.obj(prompt=req.prompt, num_inference_steps=req.steps, guidance_scale=0.0,
                             width=IMAGE_SIZE, height=IMAGE_SIZE, generator=torch_generator(seed)).images[0]
        return image, round(time.monotonic() - start, 2)

    image, seconds = run_job("image", "text→image", job)
    result = {"image": png_b64(image), "seconds": seconds, "seed": seed, "steps": req.steps, "prompt": req.prompt}
    gallery.appendleft(result)
    return result


@app.post("/api/img2img")
def img2img(
    image: UploadFile = File(...),
    prompt: str = Form(..., min_length=1, max_length=300),
    strength: float = Form(0.5, ge=0.1, le=1.0),
    steps: int = Form(2, ge=1, le=4),
    seed: int | None = Form(None, ge=0, le=2**31 - 1),
):
    models.ensure_ready("image")
    data, _ = read_upload(image, "image", MAX_IMAGE_BYTES)
    init = ImageOps.fit(open_image(data), (IMG2IMG_SIZE, IMG2IMG_SIZE), Image.Resampling.LANCZOS)
    seed = new_seed(seed)
    # diffusers runs int(steps * strength) denoising steps; make sure at least one runs.
    effective = max(steps, math.ceil(1 / strength)) if int(steps * strength) < 1 else steps

    def job(slot):
        start = time.monotonic()
        if STUB:
            out = fake_image(prompt, seed, IMG2IMG_SIZE, base=init, strength=strength)
        else:
            out = img2img_pipe(slot)(prompt=prompt, image=init, strength=strength, num_inference_steps=effective,
                                     guidance_scale=0.0, generator=torch_generator(seed)).images[0]
        return out, round(time.monotonic() - start, 2)

    out, seconds = run_job("image", "image→image", job)
    return {"image": png_b64(out), "seconds": seconds, "seed": seed, "steps": steps, "effective_steps": effective,
            "strength": strength, "prompt": prompt}


def _sse(obj) -> str:
    return "data: " + json.dumps(obj) + "\n\n"


def _chat_inputs(tokenizer, messages, dev):
    msgs = list(messages)
    while True:
        text = tokenizer.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        enc = tokenizer(text, return_tensors="pt")
        droppable = [i for i, m in enumerate(msgs[:-1]) if m["role"] != "system"]
        if enc["input_ids"].shape[1] <= CHAT_MAX_INPUT_TOKENS or not droppable:
            return enc.to(dev)
        msgs.pop(droppable[0])  # drop oldest turns until the prompt fits


def _chat_worker(slot: Slot, req: ChatRequest, out: queue.Queue, stop: threading.Event):
    start, chunks = time.monotonic(), 0
    try:
        msgs = [m.model_dump() for m in req.messages]
        if STUB:
            reply = "(stub) You said: " + msgs[-1]["content"]
            for word in reply.split(" ")[: req.max_new_tokens]:
                if stop.is_set():
                    break
                out.put({"token": word + " "})
                chunks += 1
                time.sleep(0.02)
        else:
            import torch
            from transformers import StoppingCriteria, StoppingCriteriaList, TextIteratorStreamer

            tok, model, dev = slot.obj["tokenizer"], slot.obj["model"], slot.obj["device"]
            inputs = _chat_inputs(tok, msgs, dev)
            streamer = TextIteratorStreamer(tok, skip_prompt=True, skip_special_tokens=True, timeout=120)

            class StopOnDisconnect(StoppingCriteria):
                def __call__(self, input_ids, scores, **kwargs):
                    return torch.full((input_ids.shape[0],), stop.is_set(), dtype=torch.bool, device=input_ids.device)

            kwargs = dict(**inputs, streamer=streamer, max_new_tokens=req.max_new_tokens,
                          stopping_criteria=StoppingCriteriaList([StopOnDisconnect()]),
                          pad_token_id=tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id)
            if req.temperature > 0:
                kwargs.update(do_sample=True, temperature=req.temperature, top_p=0.9)
            else:
                kwargs.update(do_sample=False)
            failure = []

            def generate_thread():
                try:
                    with torch.inference_mode():
                        model.generate(**kwargs)
                except Exception as e:  # noqa: BLE001
                    failure.append(e)
                    streamer.end()

            t = threading.Thread(target=generate_thread, daemon=True)
            t.start()
            for text in streamer:
                if text:
                    chunks += 1
                    out.put({"token": text})
            t.join()
            if failure:
                raise failure[0]
        out.put({"done": True, "seconds": round(time.monotonic() - start, 2), "chunks": chunks, "model": CHAT_MODEL})
    except Exception as e:  # noqa: BLE001
        release_memory()
        out.put({"error": err_text(e, 500)})
    finally:
        end_job(slot)  # the GPU lock is held exactly as long as generation runs
        out.put(None)


@app.post("/api/chat")
def chat(req: ChatRequest):
    if req.messages[-1].role != "user":
        raise HTTPException(400, "The last message must come from the user")
    slot = begin_job("chat", "chat")
    out: queue.Queue = queue.Queue()
    stop = threading.Event()
    try:
        threading.Thread(target=_chat_worker, args=(slot, req, out, stop), daemon=True).start()
    except Exception:
        end_job(slot)
        raise

    def events():
        try:
            while True:
                try:
                    item = out.get(timeout=180)
                except queue.Empty:
                    yield _sse({"error": "timeout"})
                    return
                if item is None:
                    return
                yield _sse(item)
        finally:
            stop.set()

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.post("/api/stt")
def stt(
    audio: UploadFile = File(...),
    language: Literal["auto", "de", "en"] = Form("auto"),
    task: Literal["transcribe", "translate"] = Form("transcribe"),
):
    models.ensure_ready("stt")
    data, ctype = read_upload(audio, "audio", MAX_AUDIO_BYTES)
    samples = decode_audio(data, ctype)
    duration = len(samples) / 16000
    if duration > MAX_AUDIO_SECONDS:
        raise HTTPException(413, f"Audio too long (max {MAX_AUDIO_SECONDS // 60} min)")
    if duration < 0.1:
        raise HTTPException(400, "Audio is empty")

    def job(slot):
        start = time.monotonic()
        if STUB:
            text = f"(stub) This is a fake {task} of {duration:.1f} s of audio (language: {language})."
            chunks = [{"start": 0.0, "end": round(duration, 2), "text": text}]
        else:
            gen = {"task": task}
            if language != "auto":
                gen["language"] = language
            res = slot.obj({"raw": samples, "sampling_rate": 16000}, chunk_length_s=30, batch_size=8,
                           return_timestamps=True, generate_kwargs=gen)
            text = res.get("text", "").strip()
            chunks = [{"start": (c.get("timestamp") or (None, None))[0], "end": (c.get("timestamp") or (None, None))[1],
                       "text": c.get("text", "").strip()} for c in res.get("chunks", [])[:500]]
        return text, chunks, round(time.monotonic() - start, 2)

    text, chunks, seconds = run_job("stt", "speech→text", job)
    return {"text": text, "chunks": chunks, "duration": round(duration, 2), "seconds": seconds,
            "language": language, "task": task, "model": STT_MODEL}


VISION_TASKS = {"caption": "<CAPTION>", "detailed_caption": "<MORE_DETAILED_CAPTION>", "ocr": "<OCR>", "od": "<OD>"}
BOX_COLORS = [(118, 185, 0), (56, 189, 248), (251, 191, 36), (244, 114, 182), (167, 139, 250), (248, 113, 113)]


def draw_boxes(img: Image.Image, boxes, labels) -> Image.Image:
    out = img.copy()
    draw = ImageDraw.Draw(out)
    width = max(2, round(max(out.size) / 300))
    for i, (box, label) in enumerate(zip(boxes, labels)):
        color = BOX_COLORS[i % len(BOX_COLORS)]
        x0, y0, x1, y1 = (float(v) for v in box)
        draw.rectangle((x0, y0, x1, y1), outline=color, width=width)
        tw = draw.textlength(label) + 8
        ty = max(0, y0 - 16)
        draw.rectangle((x0, ty, x0 + tw, ty + 16), fill=color)
        draw.text((x0 + 4, ty + 2), label, fill=(0, 0, 0))
    return out


@app.post("/api/vision")
def vision(
    image: UploadFile = File(...),
    task: Literal["caption", "detailed_caption", "ocr", "od"] = Form("caption"),
):
    models.ensure_ready("vision")
    data, _ = read_upload(image, "image", MAX_IMAGE_BYTES)
    img = open_image(data)
    img.thumbnail((VISION_MAX_SIDE, VISION_MAX_SIDE))
    prompt = VISION_TASKS[task]

    def job(slot):
        start = time.monotonic()
        w, h = img.size
        if STUB:
            if task == "od":
                parsed = {"bboxes": [[w * 0.1, h * 0.1, w * 0.5, h * 0.6], [w * 0.55, h * 0.3, w * 0.9, h * 0.9]],
                          "labels": ["stub object", "another <thing>"]}
            else:
                parsed = f"(stub) {task} of a {w}x{h} image"
        else:
            import torch

            o = slot.obj
            inputs = o["processor"](text=prompt, images=img, return_tensors="pt")
            inputs = {k: (v.to(o["device"], o["dtype"]) if v.is_floating_point() else v.to(o["device"]))
                      for k, v in inputs.items()}
            gen_args = inputs if o["kind"] == "native" else {
                "input_ids": inputs["input_ids"], "pixel_values": inputs["pixel_values"]}
            with torch.inference_mode():
                ids = o["model"].generate(**gen_args, max_new_tokens=1024, num_beams=3, do_sample=False)
            raw = o["processor"].batch_decode(ids, skip_special_tokens=False)[0]
            parsed = o["processor"].post_process_generation(raw, task=prompt, image_size=(w, h))[prompt]
        return parsed, round(time.monotonic() - start, 2)

    parsed, seconds = run_job("vision", "vision", job)
    result = {"task": task, "seconds": seconds, "model": models.slots["vision"].extra.get("variant", VISION_MODEL)}
    if task == "od":
        boxes = [[round(float(v), 1) for v in b] for b in parsed.get("bboxes", [])][:200]
        labels = [str(x) for x in parsed.get("labels", [])][: len(boxes)]
        result.update(objects=[{"label": lab, "box": b} for lab, b in zip(labels, boxes)],
                      image=png_b64(draw_boxes(img, boxes, labels)), text=", ".join(labels))
    else:
        result["text"] = str(parsed).replace("</s>", "").replace("<s>", "").strip()
    return result


@app.get("/api/gpu")
def gpu():
    stats = gpu_stats()
    source = refresh_hf_token()
    stats.update(models=[s.info() for s in models.slots.values()], busy=gpu_job["name"],
                 busy_since=gpu_job["since"], hf_token_configured=source is not None, hf_token_source=source,
                 stub=STUB, device="stub" if STUB else run_device(), version=VERSION)
    return stats


@app.post("/api/models/{name}/load", status_code=202)
def load_model(name: str):
    return {"name": name, "status": models.request_load(name)}


@app.post("/api/models/{name}/unload")
def unload_model(name: str):
    return models.unload(name)


@app.post("/api/benchmark")
def benchmark():
    slot = begin_job(None, "benchmark")
    try:
        return run_benchmark()
    finally:
        end_job(slot)


@app.get("/api/slice")
def slice_info():
    return slice_self()


@app.post("/api/slice/bench")
def slice_bench_endpoint():
    if WORKER:
        if not slice_lock.acquire(blocking=False):
            raise HTTPException(429, "Benchmark already running in this slice")
        try:
            return slice_bench()
        finally:
            slice_lock.release()
    slot = begin_job(None, "slice benchmark")
    try:
        return slice_bench()
    finally:
        end_job(slot)


@app.post("/api/slice/oom")
def slice_oom_endpoint():
    if not WORKER:
        raise HTTPException(409, "The OOM test runs only in slice workers (the playground keeps its models)")
    if not slice_lock.acquire(blocking=False):
        raise HTTPException(429, "Another test is running in this slice")
    try:
        return slice_oom()
    finally:
        slice_lock.release()


def _members() -> list[dict]:
    me = slice_self()
    with ThreadPoolExecutor(max_workers=max(1, len(SLICE_WORKERS))) as ex:
        peers = list(ex.map(lambda w: _peer("GET", w["url"] + "/api/slice", 3), SLICE_WORKERS))
    members = [me]
    for w, p in zip(SLICE_WORKERS, peers):
        p = dict(p)
        p.setdefault("name", w["name"])
        p.setdefault("role", "worker")
        p["mem_gib"], p["core_percent"] = w.get("mem_gib"), w.get("core_percent")
        members.append(p)
    return members


@app.get("/api/slicing")
def slicing():
    enabled = bool(SLICE_NAME) and not WORKER
    return {"enabled": enabled, "card_gb": CARD_MEM_GIB, "members": _members() if enabled else [],
            "stub": STUB, "version": VERSION}


@app.post("/api/slicing/bench")
def slicing_bench():
    """Benchmark the playground slice and all workers at the same time."""
    if not SLICE_NAME or WORKER:
        raise HTTPException(409, "GPU slicing is not enabled")

    def own():
        try:
            return slice_bench_endpoint()
        except HTTPException as e:
            return {"error": e.detail}

    timeout = SLICE_BENCH_SECONDS + 60  # first call initialises CUDA in the worker
    with ThreadPoolExecutor(max_workers=len(SLICE_WORKERS) + 1) as ex:
        futures = [ex.submit(own)] + [ex.submit(_peer, "POST", w["url"] + "/api/slice/bench", timeout)
                                      for w in SLICE_WORKERS]
        results = [f.result() for f in futures]
    names = [SLICE_NAME] + [w["name"] for w in SLICE_WORKERS]
    cores = [SLICE_CORE_PERCENT or None] + [w.get("core_percent") for w in SLICE_WORKERS]
    return {"results": [dict(r, name=n, core_percent=c) for n, c, r in zip(names, cores, results)]}


@app.post("/api/slicing/oom/{name}")
def slicing_oom(name: str):
    if not SLICE_NAME or WORKER:
        raise HTTPException(409, "GPU slicing is not enabled")
    return dict(_peer("POST", _worker(name)["url"] + "/api/slice/oom", 180), name=name)


@app.get("/", response_class=HTMLResponse)
def index():
    return PAGE


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GPU AI Playground</title>
<style>
  :root { --bg:#0b1020; --panel:#121a2f; --panel-2:#172241; --line:#24304f; --text:#e6e9f2; --muted:#8b93a7;
          --accent:#76b900; --accent-2:#4c8c00; --ok:#34d399; --warn:#fbbf24; --err:#f87171; }
  * { box-sizing:border-box; margin:0; padding:0; }
  [hidden] { display:none !important; }
  body { font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; color:var(--text); min-height:100vh;
         background: radial-gradient(1200px 600px at 10% -10%, #1d2a55 0%, transparent 60%),
                     radial-gradient(900px 500px at 110% 10%, #1f3a08 0%, transparent 55%), var(--bg); }
  .wrap { max-width:1160px; margin:0 auto; padding:32px 20px 48px; }
  header { display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom:20px; flex-wrap:wrap; }
  .brand { display:flex; align-items:center; gap:14px; }
  .logo { width:44px; height:44px; border-radius:12px; display:grid; place-items:center; font-weight:800; font-size:18px;
          background:linear-gradient(135deg,var(--accent),var(--accent-2)); color:#0b1400; box-shadow:0 8px 24px rgba(118,185,0,.35); }
  h1 { font-size:22px; } .sub { color:var(--muted); font-size:13px; }
  .pill { display:inline-flex; align-items:center; gap:8px; padding:6px 12px; border-radius:999px; background:var(--panel);
          border:1px solid var(--line); font-size:12px; color:var(--muted); }
  .dot { width:8px; height:8px; flex:none; border-radius:50%; background:var(--warn); box-shadow:0 0 10px var(--warn); }
  .dot.ok { background:var(--ok); box-shadow:0 0 10px var(--ok); } .dot.err { background:var(--err); box-shadow:0 0 10px var(--err); }
  .dot.off { background:#4b5563; box-shadow:none; }
  .tabs { display:flex; gap:6px; padding:6px; margin-bottom:20px; border-radius:14px; background:var(--panel);
          border:1px solid var(--line); overflow-x:auto; }
  .tabs button { margin:0; background:transparent; color:var(--muted); box-shadow:none; padding:8px 16px; font-weight:600;
    white-space:nowrap; }
  .tabs button:hover { color:var(--text); }
  .tabs button.active { background:linear-gradient(135deg,var(--accent),var(--accent-2)); color:#0b1400; }
  .grid { display:grid; grid-template-columns:1.3fr 1fr; gap:20px; }
  .grid.wide { grid-template-columns:2fr 1fr; }
  @media (max-width:860px) { .grid, .grid.wide { grid-template-columns:1fr; } }
  .card { background:linear-gradient(180deg,var(--panel),#0f1629); border:1px solid var(--line); border-radius:16px; padding:22px;
          box-shadow:0 10px 30px rgba(0,0,0,.25); }
  .card + .card { margin-top:20px; }
  .grid > .card + .card { margin-top:0; }
  h2 { font-size:15px; margin-bottom:12px; }
  .explain { color:var(--muted); font-size:13px; margin-bottom:14px; }
  textarea, input[type=text], select { width:100%; background:#0c1326; border:1px solid var(--line); border-radius:12px;
             color:var(--text); padding:10px 12px; font:inherit; line-height:1.4; }
  textarea { min-height:90px; resize:vertical; }
  select { width:auto; padding:7px 10px; border-radius:10px; }
  textarea:focus, input:focus, select:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px rgba(118,185,0,.15); }
  .row { display:flex; gap:12px; align-items:center; margin-top:14px; flex-wrap:wrap; }
  label { color:var(--muted); font-size:12px; } input[type=range] { accent-color:var(--accent); vertical-align:middle; }
  input[type=number] { width:110px; background:#0c1326; border:1px solid var(--line); border-radius:10px; color:var(--text);
    padding:7px 10px; }
  button { border:0; border-radius:10px; padding:10px 20px; font-weight:700; cursor:pointer; color:#0b1400;
           background:linear-gradient(135deg,var(--accent),var(--accent-2)); box-shadow:0 6px 18px rgba(118,185,0,.25); }
  button.push { margin-left:auto; }
  button.ghost { background:transparent; color:var(--text); border:1px solid var(--line); box-shadow:none; padding:6px 12px;
    font-weight:600; }
  button.ghost:hover { border-color:var(--accent); }
  button.danger { color:var(--err); }
  button:disabled { opacity:.5; cursor:wait; }
  .mbar { display:flex; align-items:center; gap:10px; padding:10px 14px; margin-bottom:16px; border-radius:12px;
          background:var(--panel); border:1px solid var(--line); font-size:13px; }
  .mbar .mtext { color:var(--muted); flex:1; overflow-wrap:anywhere; }
  .stage { aspect-ratio:1; border-radius:14px; border:1px dashed var(--line); display:grid; place-items:center; overflow:hidden;
           background:#0c1326; color:var(--muted); margin-top:16px; text-align:center; padding:0; }
  .stage img { width:100%; height:100%; object-fit:contain; }
  .stage.small { aspect-ratio:16/10; }
  .meta { color:var(--muted); font-size:12px; margin-top:8px; min-height:18px; }
  .msgbox { margin-top:10px; font-size:13px; min-height:18px; }
  .msgbox.err { color:var(--err); } .msgbox.warn { color:var(--warn); }
  .chips { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
  .chip { font-size:12px; padding:4px 10px; border-radius:999px; background:var(--panel-2); border:1px solid var(--line); cursor:pointer; }
  .chip:hover { border-color:var(--accent); }
  .chip.sel { border-color:var(--accent); background:#1d3a0a; }
  dl { display:grid; grid-template-columns:auto 1fr; gap:6px 14px; font-size:13px; } dt { color:var(--muted);
    } dd { overflow-wrap:anywhere; }
  .gallery { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }
  .gallery img { width:100%; border-radius:10px; border:1px solid var(--line); cursor:pointer; }
  .spinner { width:28px; height:28px; border:3px solid var(--line); border-top-color:var(--accent);
             border-radius:50%; animation:spin 1s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  a.dl { display:inline-block; margin-top:10px; color:var(--accent); font-weight:600; font-size:13px; text-decoration:none; }
  .drop { display:flex; flex-direction:column; gap:6px; padding:14px; border:1px dashed var(--line); border-radius:12px;
    background:#0c1326; }
  input[type=file] { color:var(--muted); font-size:12px; }
  .chatlog { height:440px; overflow-y:auto; display:flex; flex-direction:column; gap:10px; padding:4px 2px 4px 0; }
  .msg { max-width:85%; padding:10px 14px; border-radius:14px; white-space:pre-wrap; overflow-wrap:anywhere; border:1px solid var(--line); }
  .msg.user { align-self:flex-end; background:#1d3a0a; border-color:#2f5a10; }
  .msg.assistant { align-self:flex-start; background:var(--panel-2); }
  .msg.err { border-color:var(--err); }
  .msg.typing::after { content:"▍"; color:var(--accent); animation:blink 1s steps(2) infinite; }
  @keyframes blink { 50% { opacity:0; } }
  .empty { color:var(--muted); margin:auto; text-align:center; }
  .result { white-space:pre-wrap; overflow-wrap:anywhere; background:#0c1326; border:1px solid var(--line); border-radius:12px;
            padding:12px; min-height:120px; }
  .segs { margin-top:12px; max-height:240px; overflow-y:auto; font-size:12px; color:var(--muted); }
  .segs div { padding:3px 0; border-bottom:1px solid var(--line); } .segs b { color:var(--accent); font-weight:600; margin-right:8px; }
  .rec { display:inline-flex; align-items:center; gap:8px; font-variant-numeric:tabular-nums; color:var(--muted); }
  .rec .dot { background:var(--err); box-shadow:0 0 10px var(--err); animation:blink 1s steps(2) infinite; }
  audio { width:100%; margin-top:10px; }
  .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; }
  .stat { background:#0c1326; border:1px solid var(--line); border-radius:12px; padding:12px; }
  .stat .k { color:var(--muted); font-size:12px; } .stat .v { font-size:20px; font-weight:700; margin:2px 0 6px;
    font-variant-numeric:tabular-nums; }
  .bar { height:8px; background:#1a2340; border-radius:99px; overflow:hidden; }
  .bar > i { display:block; height:100%; width:0; background:linear-gradient(90deg,var(--accent),#b6f03c); transition:width .4s; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--line); vertical-align:middle; }
  th { color:var(--muted); font-weight:600; font-size:12px; }
  td .dot { display:inline-block; margin-right:6px; }
  .sbar { display:flex; height:26px; border-radius:8px; overflow:hidden; background:#1a2340; margin:6px 0 14px;
          border:1px solid var(--line); }
  .sbar span { display:block; height:100%; font-size:11px; font-weight:700; color:#0b1400; padding:0 6px; line-height:26px;
               white-space:nowrap; overflow:hidden; text-overflow:ellipsis; border-right:2px solid #0b1020; }
  .sbar span.free { background:transparent; color:var(--muted); font-weight:500; border-right:0; }
  .swatch { display:inline-block; width:10px; height:10px; border-radius:3px; margin-right:6px; vertical-align:middle; }
  .opts td:first-child { white-space:nowrap; font-weight:600; }
  footer { margin-top:28px; text-align:center; color:var(--muted); font-size:12px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand"><div class="logo">AI</div>
      <div><h1>GPU AI Playground</h1>
        <div class="sub">Image, chat, speech &amp; vision models sharing one NVIDIA GPU on T-Cloud CCE</div></div>
    </div>
    <div class="pill"><span class="dot" id="dot"></span><span id="state">Connecting…</span></div>
  </header>

  <nav class="tabs" id="tabs">
    <button data-tab="t2i">Text → Image</button>
    <button data-tab="i2i">Image → Image</button>
    <button data-tab="chat">Chat</button>
    <button data-tab="stt">Speech → Text</button>
    <button data-tab="vision">Vision</button>
    <button data-tab="gpu">GPU</button>
    <button data-tab="slicing">GPU Slicing</button>
  </nav>

  <!-- Text → Image -->
  <section class="panel" id="tab-t2i">
    <div class="mbar" data-model="image"><span class="dot"></span><span class="mtext">…</span>
      <button class="ghost" hidden>Load model</button></div>
    <div class="grid">
      <section class="card">
        <h2>Prompt</h2>
        <p class="explain">SDXL-Turbo turns a text prompt into a 512×512 image in 1–4 denoising steps (no guidance needed). Same seed +
          prompt = same image.</p>
        <textarea id="prompt" maxlength="300">A cinematic photo of a magenta cloud server rack in a misty forest, golden hour</textarea>
        <div class="chips" id="chips"></div>
        <div class="row">
          <label>Steps <input type="range" id="steps" min="1" max="4" value="2"> <span id="stepsv">2</span></label>
          <label>Seed <input type="number" id="seed" placeholder="random" min="0"></label>
          <button id="go" class="push">Generate</button>
        </div>
        <div class="stage" id="stage">Your image appears here</div>
        <div class="meta" id="meta"></div>
        <div id="t2idl"></div>
      </section>
      <div>
        <section class="card"><h2>Node</h2><dl id="info"><dt>Status</dt><dd>…</dd></dl></section>
        <section class="card"><h2>Recent</h2><div class="gallery" id="gallery"></div></section>
      </div>
    </div>
  </section>

  <!-- Image → Image -->
  <section class="panel" id="tab-i2i" hidden>
    <div class="mbar" data-model="image"><span class="dot"></span><span class="mtext">…</span>
      <button class="ghost" hidden>Load model</button></div>
    <div class="grid">
      <section class="card">
        <h2>Input image &amp; prompt</h2>
        <p class="explain">Re-uses the already loaded SDXL-Turbo weights (no extra VRAM). The image is cropped to 512×512; <b>strength</b>
          controls how far the result may drift from the input (0.1 = subtle, 1.0 = ignore input).</p>
        <label class="drop">Image (PNG/JPEG/WebP, max 10 MB)<input type="file" id="i2iFile" accept="image/*"></label>
        <div class="stage small" id="i2iPrev">No image selected</div>
        <textarea id="i2iPrompt" maxlength="300" style="margin-top:14px">Turn this into a watercolor painting, soft pastel colors</textarea>
        <div class="chips" id="i2iChips"></div>
        <div class="row">
          <label>Strength <input type="range" id="i2iStrength" min="0.1" max="1" step="0.05" value="0.5">
            <span id="i2iStrengthv">0.50</span></label>
          <label>Steps <input type="range" id="i2iSteps" min="1" max="4" value="2"> <span id="i2iStepsv">2</span></label>
          <label>Seed <input type="number" id="i2iSeed" placeholder="random" min="0"></label>
          <button id="i2iGo" class="push">Transform</button>
        </div>
        <div class="msgbox" id="i2iMsg"></div>
      </section>
      <section class="card">
        <h2>Result</h2>
        <div class="stage" id="i2iStage">Result appears here</div>
        <div class="meta" id="i2iMeta"></div>
        <div id="i2idl"></div>
      </section>
    </div>
  </section>

  <!-- Chat -->
  <section class="panel" id="tab-chat" hidden>
    <div class="mbar" data-model="chat"><span class="dot"></span><span class="mtext">…</span>
      <button class="ghost" hidden>Load model</button></div>
    <div class="grid wide">
      <section class="card">
        <h2>Chat</h2>
        <div class="chatlog" id="chatLog">
          <div class="empty" id="chatEmpty">Ask anything – answers are streamed token by token from the GPU.</div></div>
        <textarea id="chatIn" maxlength="8000" placeholder="Message… (Enter to send, Shift+Enter for a new line)"
          style="margin-top:14px;min-height:70px"></textarea>
        <div class="row">
          <span class="meta" id="chatMeta" style="margin:0"></span>
          <button class="ghost push" id="chatClear">Clear</button>
          <button class="ghost danger" id="chatStop" hidden>Stop</button>
          <button id="chatSend">Send</button>
        </div>
      </section>
      <div>
        <section class="card">
          <h2>Settings</h2>
          <p class="explain">A small instruct LLM. The conversation lives only in your browser; the full history is sent with every
            message.</p>
          <label>System prompt (optional)</label>
          <textarea id="sysPrompt" maxlength="4000" style="min-height:70px">You are a helpful assistant. Answer concisely.</textarea>
          <div class="row">
            <label>Max tokens <input type="range" id="chatMax" min="32" max="512" step="32" value="256"> <span id="chatMaxv">256</span>
              </label></div>
          <div class="row">
            <label>Temperature <input type="range" id="chatTemp" min="0" max="1.5" step="0.1" value="0.7">
              <span id="chatTempv">0.7</span></label></div>
        </section>
        <section class="card"><h2>Try</h2><div class="chips" id="chatChips"></div></section>
      </div>
    </div>
  </section>

  <!-- Speech → Text -->
  <section class="panel" id="tab-stt" hidden>
    <div class="mbar" data-model="stt"><span class="dot"></span><span class="mtext">…</span>
      <button class="ghost" hidden>Load model</button></div>
    <div class="grid">
      <section class="card">
        <h2>Audio</h2>
        <p class="explain">Whisper transcribes speech (max 5 min, 25 MB). Upload a file (wav, mp3, ogg, webm, m4a, flac) or record
          with your microphone (needs HTTPS or localhost). <i>Translate</i> produces English text.</p>
        <label class="drop">Audio file<input type="file" id="sttFile" accept="audio/*,.webm,.ogg,.mp3,.wav,.m4a,.flac"></label>
        <div class="row">
          <button class="ghost" id="recBtn">● Record</button>
          <span class="rec" id="recInfo" hidden><span class="dot"></span><span id="recTime">0:00</span></span>
          <span class="meta" id="sttSrc" style="margin:0"></span>
        </div>
        <audio id="sttAudio" controls hidden></audio>
        <div class="row">
          <label>Language <select id="sttLang"><option value="auto">auto-detect</option><option value="de">German</option>
            <option value="en">English</option></select></label>
          <label>Task <select id="sttTask"><option value="transcribe">transcribe</option>
            <option value="translate">translate → English</option></select></label>
          <button id="sttGo" class="push">Transcribe</button>
        </div>
        <div class="msgbox" id="sttMsg"></div>
      </section>
      <section class="card">
        <h2>Transcript</h2>
        <div class="result" id="sttOut">The transcript appears here.</div>
        <div class="row" style="margin-top:8px"><span class="meta" id="sttMeta" style="margin:0"></span>
          <button class="ghost push" id="sttCopy">Copy</button></div>
        <div class="segs" id="sttSegs"></div>
      </section>
    </div>
  </section>

  <!-- Vision -->
  <section class="panel" id="tab-vision" hidden>
    <div class="mbar" data-model="vision"><span class="dot"></span><span class="mtext">…</span>
      <button class="ghost" hidden>Load model</button></div>
    <div class="grid">
      <section class="card">
        <h2>Image understanding</h2>
        <p class="explain">Florence-2 describes images, reads text (OCR) and detects objects. Detected objects are drawn as boxes on
          the server.</p>
        <label class="drop">Image (max 10 MB)<input type="file" id="visFile" accept="image/*"></label>
        <div class="stage small" id="visPrev">No image selected</div>
        <div class="chips" id="visTasks" style="margin-top:14px">
          <span class="chip sel" data-task="caption">Caption</span>
          <span class="chip" data-task="detailed_caption">Detailed caption</span>
          <span class="chip" data-task="ocr">OCR (read text)</span>
          <span class="chip" data-task="od">Object detection</span>
        </div>
        <div class="row"><button id="visGo" class="push">Analyze</button></div>
        <div class="msgbox" id="visMsg"></div>
      </section>
      <section class="card">
        <h2>Result</h2>
        <div class="stage small" id="visStage">Annotated image appears here (object detection)</div>
        <div class="result" id="visOut" style="margin-top:14px">The answer appears here.</div>
        <div class="chips" id="visLabels"></div>
        <div class="meta" id="visMeta"></div>
        <div id="visdl"></div>
      </section>
    </div>
  </section>

  <!-- GPU -->
  <section class="panel" id="tab-gpu" hidden>
    <section class="card">
      <h2>Live GPU <span class="meta" id="gpuName"></span></h2>
      <div id="gpuNone" class="explain" hidden></div>
      <div class="stats" id="gpuStats">
        <div class="stat"><div class="k">Utilisation</div><div class="v" id="gUtil">–</div><div class="bar"><i id="gUtilBar"></i></div>
          </div>
        <div class="stat"><div class="k">VRAM</div><div class="v" id="gMem">–</div><div class="bar"><i id="gMemBar"></i></div></div>
        <div class="stat"><div class="k">Temperature</div><div class="v" id="gTemp">–</div><div class="bar"><i id="gTempBar"></i></div>
          </div>
        <div class="stat"><div class="k">Power</div><div class="v" id="gPower">–</div><div class="bar"><i id="gPowerBar"></i></div></div>
        <div class="stat"><div class="k">SM clock</div><div class="v" id="gClock">–</div><div class="bar"><i id="gClockBar"></i></div></div>
        <div class="stat"><div class="k">Memory clock</div><div class="v" id="gMClock">–</div><div class="meta" id="gTorch"></div></div>
      </div>
    </section>
    <section class="card">
      <h2>Models</h2>
      <p class="explain">Models load lazily on first use. When VRAM runs short the least-recently-used idle model is unloaded
        (SDXL-Turbo is kept longest).</p>
      <table><thead><tr><th>Model</th><th>Status</th><th>VRAM (measured / est.)</th><th>Load time</th><th>Last used</th><th></th></tr>
        </thead>
        <tbody id="modelRows"></tbody></table>
      <div class="msgbox" id="modelMsg"></div>
    </section>
    <div class="grid" style="margin-top:20px">
      <section class="card">
        <h2>CPU vs GPU</h2>
        <p class="explain">Multiplies two 2048×2048 matrices (≈17 GFLOP each) on the CPU (a few times, max ~4 s) and on the GPU (fp32
          and fp16).</p>
        <div class="row" style="margin-top:0"><button id="benchGo">Run benchmark</button></div>
        <div id="benchOut" style="margin-top:14px"></div>
        <div class="msgbox" id="benchMsg"></div>
      </section>
      <section class="card"><h2>Environment</h2><dl id="envInfo"><dt>…</dt><dd></dd></dl></section>
    </div>
  </section>

  <!-- GPU slicing -->
  <section class="panel" id="tab-slicing" hidden>
    <section class="card" id="slOff" hidden>
      <h2>GPU slicing is not enabled</h2>
      <p class="explain">Right now the playground owns the whole GPU. With CCE xGPU one GPU is split into slices with a hard
        VRAM and compute limit per pod, and several pods share the card. Enable it with <code>gpu_xgpu = true</code> in the infra
        stack (GPU addon + Volcano scheduler); the workloads stack then deploys the playground in a slice plus a few slice workers.
        See docs/gpu.md → GPU slicing.</p>
    </section>
    <div id="slOn" hidden>
      <section class="card">
        <h2>One GPU, several pods <span class="meta" id="slGpu"></span></h2>
        <p class="explain">Volcano places every pod on the same GPU; CCE xGPU enforces each slice: a pod sees only its VRAM
          and gets at most its share of the compute time. The playground models run in their own slice.</p>
        <div class="k">VRAM (of ~<span id="slCard">22</span> GiB usable)</div><div class="sbar" id="slMemBar"></div>
        <div class="k">Compute</div><div class="sbar" id="slCoreBar"></div>
      </section>
      <section class="card">
        <h2>Pods</h2>
        <table><thead><tr><th>Slice</th><th>Pod / node</th><th>VRAM slice</th><th>VRAM seen by the pod</th><th>Compute</th>
          <th>Last benchmark</th><th>Isolation test</th></tr></thead><tbody id="slRows"></tbody></table>
        <p class="explain" style="margin-top:12px">“VRAM seen by the pod” comes from <code>torch.cuda.mem_get_info()</code> inside
          the pod – with xGPU it reports the slice, not the 24 GB card. The isolation test allocates memory until the driver
          refuses (stops 1 GiB above the slice).</p>
        <div class="msgbox" id="slMsg"></div>
      </section>
      <section class="card">
        <h2>Benchmark all slices at once</h2>
        <p class="explain">Every pod multiplies fp16 4096×4096 matrices for ~6 s at the same time. With hard compute limits the
          measured throughput follows the configured share.</p>
        <div class="row" style="margin-top:0"><button id="slBench">Run on all slices</button></div>
        <div id="slBenchOut" style="margin-top:14px"></div>
        <div class="msgbox" id="slBenchMsg"></div>
      </section>
    </div>
    <section class="card">
      <h2>Ways to share a GPU</h2>
      <table class="opts"><tbody>
        <tr><td>Whole GPU</td><td>One pod per card (<code>nvidia.com/gpu: 1</code>) – the default of this demo.</td></tr>
        <tr><td>Time-slicing</td><td>NVIDIA device plugin hands the same card to several pods; no VRAM or fault isolation.
          Not offered by the CCE addon.</td></tr>
        <tr><td>MIG</td><td>Hardware partitions with own memory and SMs – only A100/H100/A30, not the L4.</td></tr>
        <tr><td>CCE xGPU</td><td>Software slices with hard VRAM (128 MiB steps) and compute (percent) limits, up to 20 per card;
          scheduled by Volcano (<code>volcano.sh/gpu-mem.128Mi</code>, <code>volcano.sh/gpu-core.percentage</code>).</td></tr>
      </tbody></table>
    </section>
  </section>
  <footer id="foot"></footer>
</div>
<script>
"use strict";
const $ = id => document.getElementById(id);
function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v; else if (k === "text") e.textContent = v;
    else if (k.startsWith("on")) e[k] = v; else e.setAttribute(k, v);
  }
  for (const c of kids) if (c !== null && c !== undefined) e.append(c);
  return e;
}
const fmtS = s => s == null ? "–" : s + " s";
const ago = t => { if (!t) return "never"; const d = Math.max(0, Date.now() / 1000 - t);
  return d < 60 ? Math.round(d) + " s ago" : d < 3600 ? Math.round(d / 60) + " min ago" : Math.round(d / 3600) + " h ago"; };
const MB = 1024 * 1024;
let lastStatus = null;

class ApiError extends Error { constructor(msg, status) { super(msg); this.status = status; } }
function errText(status, d) {
  if (status === 429) return "The GPU is busy with another job – please try again in a few seconds.";
  let detail = d && d.detail;
  if (Array.isArray(detail)) detail = detail.map(x => (x.loc || []).slice(-1)[0] + ": " + x.msg).join("; ");
  if (status === 409) { refreshStatus(); return (detail || "Model is loading") +
    ". Loading starts automatically – watch the badge above."; }
  if (status === 413) return detail || "Upload too large.";
  return detail || ("Request failed (HTTP " + status + ")");
}
async function api(path, opts = {}) {
  const r = await fetch(path, opts);
  let d = null; try { d = await r.json(); } catch (e) { /* not JSON */ }
  if (!r.ok) throw new ApiError(errText(r.status, d), r.status);
  return d;
}
const postJSON = (path, body) => api(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
function say(id, text, kind = "err") { const m = $(id); m.textContent = text || ""; m.className = "msgbox " + (text ? kind : ""); }
function spinner(stage) { stage.replaceChildren(el("div", {class: "spinner"})); }
function showImg(stage, b64, alt) { stage.replaceChildren(el("img", {alt: alt || "result", src: "data:image/png;base64," + b64})); }
function dlLink(box, b64, name) {
  $(box).replaceChildren(el("a", {class: "dl", href: "data:image/png;base64," + b64, download: name, text: "⬇ Download PNG"}));
}
function chips(box, items, onpick) { items.forEach(t => $(box).append(el("span", {class: "chip", text: t, onclick: () => onpick(t)}))); }
function slider(id, fmt = v => v) { const f = () => $(id + "v").textContent = fmt($(id).value); $(id).oninput = f; f(); }

/* ---------- tabs ---------- */
function showTab(name) {
  if (!$("tab-" + name)) name = "t2i";
  document.querySelectorAll(".panel").forEach(p => p.hidden = p.id !== "tab-" + name);
  document.querySelectorAll("#tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === name));
  if (location.hash !== "#" + name) history.replaceState(null, "", "#" + name);
  if (name === "gpu") refreshGpu();
  if (name === "slicing") refreshSlicing();
}
document.querySelectorAll("#tabs button").forEach(b => b.onclick = () => showTab(b.dataset.tab));

/* ---------- status / model badges ---------- */
const LABEL = {ready: "ready", loading: "loading…", not_loaded: "not loaded – loads on first use", error: "failed to load"};
const DOT = {ready: "ok", error: "err", not_loaded: "off"};
document.querySelectorAll(".mbar button").forEach(b => b.onclick = async () => {
  b.disabled = true;
  try { await api("api/models/" + b.closest(".mbar").dataset.model + "/load", {method: "POST"}); } catch (e) { alert(e.message); }
  b.disabled = false; refreshStatus();
});
function updateBadges(s) {
  document.querySelectorAll(".mbar").forEach(b => {
    const m = s.models[b.dataset.model]; if (!m) return;
    b.querySelector(".dot").className = "dot " + (DOT[m.status] || "");
    let t = `${m.title} (${m.model_id}): ${LABEL[m.status] || m.status}`;
    if (m.status === "loading" && m.progress) t += " — " + m.progress;
    if (m.status === "ready" && m.load_seconds != null) t += ` · loaded in ${m.load_seconds} s`;
    if (m.status === "error" && m.error) t += " — " + m.error;
    if (m.status === "not_loaded" && m.note) t += " (" + m.note + ")";
    b.querySelector(".mtext").textContent = t;
    const btn = b.querySelector("button");
    btn.hidden = !(m.status === "not_loaded" || m.status === "error");
    btn.textContent = m.status === "error" ? "Retry load" : "Load model";
  });
}
async function refreshStatus() {
  let s;
  try { s = await api("api/status"); }
  catch (e) { $("state").textContent = "Server unreachable"; $("dot").className = "dot err"; return; }
  lastStatus = s;
  updateBadges(s);
  const loading = Object.values(s.models).filter(m => m.status === "loading").map(m => m.name);
  const g = s.gpu || {};
  $("state").textContent = (s.stub ? "STUB mode · " : "") + (g.name || "GPU") + " · " +
    (s.busy ? "busy: " + s.busy : loading.length ? "loading " + loading.join(", ") : "idle");
  $("dot").className = "dot " + (s.busy || loading.length ? "" : "ok");
  const img = s.models.image;
  $("info").replaceChildren(...[["Status", (LABEL[img.status] || img.status) + (img.error ? " — " + img.error : "")],
    ["GPU", g.name || "–"], ["VRAM", g.memory_gb ? g.memory_gb + " GB" : "–"], ["CUDA", g.cuda || "–"], ["Model", s.model],
    ["Load time", fmtS(s.load_seconds)], ["Size", `${s.size}×${s.size}`]].flatMap(([k, v]) => [el("dt", {text: k}), el("dd", {text: v})]));
  $("foot").textContent = "Build " + s.version + (s.stub ? " · STUB_MODELS=1 (fake models)" : "");
}
setInterval(refreshStatus, 3000);

/* ---------- Text → Image ---------- */
chips("chips", ["Isometric data center made of LEGO", "Watercolor of a robot sorting magenta cubes",
  "Neon city at night, rain, 35mm photo", "A friendly octopus operating a GPU cluster"], t => $("prompt").value = t);
slider("steps");
function showT2i(r) {
  showImg($("stage"), r.image, r.prompt);
  $("meta").textContent = `${r.seconds}s · ${r.steps} step(s) · seed ${r.seed}`;
  dlLink("t2idl", r.image, `sdxl-turbo-${r.seed}.png`);
}
async function gallery() {
  let items = []; try { items = await api("api/gallery"); } catch (e) { return; }
  $("gallery").replaceChildren(...items.map(r => el("img",
    {src: "data:image/png;base64," + r.image, title: r.prompt, alt: r.prompt, onclick: () => showT2i(r)})));
}
$("go").onclick = async () => {
  $("go").disabled = true; spinner($("stage")); $("meta").textContent = ""; $("t2idl").replaceChildren();
  const body = {prompt: $("prompt").value, steps: +$("steps").value};
  if ($("seed").value !== "") body.seed = +$("seed").value;
  try { showT2i(await postJSON("api/generate", body)); gallery(); }
  catch (e) { $("stage").textContent = e.message; }
  $("go").disabled = false;
};

/* ---------- Image → Image ---------- */
let i2iFile = null;
function pickImage(input, prevId, msgId, cb) {
  const f = input.files[0]; if (!f) return;
  if (!f.type.startsWith("image/")) { say(msgId, "Please choose an image file."); input.value = ""; return; }
  if (f.size > 10 * MB) { say(msgId, "Image is larger than 10 MB."); input.value = ""; return; }
  say(msgId, ""); cb(f);
  $(prevId).replaceChildren(el("img", {alt: "input", src: URL.createObjectURL(f)}));
}
$("i2iFile").onchange = e => pickImage(e.target, "i2iPrev", "i2iMsg", f => i2iFile = f);
chips("i2iChips", ["Turn this into a watercolor painting, soft pastel colors", "Cyberpunk neon style, night, rain",
  "Pencil sketch, high detail", "Make it look like a Van Gogh painting"], t => $("i2iPrompt").value = t);
slider("i2iStrength", v => (+v).toFixed(2)); slider("i2iSteps");
$("i2iGo").onclick = async () => {
  if (!i2iFile) { say("i2iMsg", "Choose an input image first."); return; }
  const fd = new FormData();
  fd.append("image", i2iFile); fd.append("prompt", $("i2iPrompt").value);
  fd.append("strength", $("i2iStrength").value); fd.append("steps", $("i2iSteps").value);
  if ($("i2iSeed").value !== "") fd.append("seed", $("i2iSeed").value);
  $("i2iGo").disabled = true; say("i2iMsg", ""); spinner($("i2iStage")); $("i2iMeta").textContent = ""; $("i2idl").replaceChildren();
  try {
    const r = await api("api/img2img", {method: "POST", body: fd});
    showImg($("i2iStage"), r.image, r.prompt);
    $("i2iMeta").textContent = `${r.seconds}s · strength ${r.strength} · ${r.effective_steps} step(s) · seed ${r.seed}`;
    dlLink("i2idl", r.image, `img2img-${r.seed}.png`);
  } catch (e) { $("i2iStage").textContent = "Result appears here"; say("i2iMsg", e.message, e.status === 409 ? "warn" : "err"); }
  $("i2iGo").disabled = false;
};

/* ---------- Chat ---------- */
let chatHistory = [], chatAbort = null;
slider("chatMax"); slider("chatTemp");
chips("chatChips", ["Explain what a GPU does in three sentences.", "Erkläre Kubernetes einem Kind.",
  "Write a haiku about cloud computing.", "What are the pros and cons of running LLMs on your own GPU?"],
  t => { $("chatIn").value = t; $("chatIn").focus(); });
function addMsg(role, text) {
  $("chatEmpty").hidden = true;
  const m = el("div", {class: "msg " + role, text});
  $("chatLog").append(m); $("chatLog").scrollTop = $("chatLog").scrollHeight; return m;
}
function chatBusy(b) { $("chatSend").disabled = b; $("chatStop").hidden = !b; }
async function sendChat() {
  const text = $("chatIn").value.trim();
  if (!text || chatAbort) return;
  chatHistory.push({role: "user", content: text}); addMsg("user", text); $("chatIn").value = "";
  const bubble = addMsg("assistant", ""); bubble.classList.add("typing");
  const msgs = []; const sys = $("sysPrompt").value.trim();
  if (sys) msgs.push({role: "system", content: sys});
  msgs.push(...chatHistory);
  chatAbort = new AbortController(); chatBusy(true); $("chatMeta").textContent = "";
  let reply = "";
  try {
    const r = await fetch("api/chat", {method: "POST", headers: {"Content-Type": "application/json"}, signal: chatAbort.signal,
      body: JSON.stringify({messages: msgs, max_new_tokens: +$("chatMax").value, temperature: +$("chatTemp").value})});
    if (!r.ok) { let d = null; try { d = await r.json(); } catch (e) { /* ignore */ } throw new ApiError(errText(r.status, d), r.status); }
    const reader = r.body.getReader(), dec = new TextDecoder(); let buf = "";
    for (;;) {
      const {value, done} = await reader.read(); if (done) break;
      buf += dec.decode(value, {stream: true});
      let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const ev = buf.slice(0, i); buf = buf.slice(i + 2);
        for (const line of ev.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          const d = JSON.parse(line.slice(6));
          if (d.token) { reply += d.token; bubble.textContent = reply; $("chatLog").scrollTop = $("chatLog").scrollHeight; }
          else if (d.error) throw new Error(d.error);
          else if (d.done) $("chatMeta").textContent = `${d.seconds} s · ${d.chunks} chunks · ${d.model}`;
        }
      }
    }
    chatHistory.push({role: "assistant", content: reply || "(empty answer)"});
  } catch (e) {
    if (e.name === "AbortError") {
      chatHistory.push({role: "assistant", content: reply || "(stopped)"}); bubble.textContent = reply + " [stopped]";
    }
    else {
      bubble.classList.add("err"); bubble.textContent = (reply ? reply + "\n\n" : "") + "⚠ " + e.message;
      if (!reply) { chatHistory.pop(); $("chatIn").value = text; } else chatHistory.push({role: "assistant", content: reply});
    }
  }
  bubble.classList.remove("typing"); chatAbort = null; chatBusy(false);
}
$("chatSend").onclick = sendChat;
$("chatStop").onclick = () => chatAbort && chatAbort.abort();
$("chatIn").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendChat(); }
});
$("chatClear").onclick = () => {
  if (chatAbort) chatAbort.abort();
  chatHistory = []; $("chatLog").replaceChildren($("chatEmpty")); $("chatEmpty").hidden = false; $("chatMeta").textContent = "";
};

/* ---------- Speech → Text ---------- */
let sttFile = null, rec = null, recTimer = null;
const EXT_TYPES = {webm: "audio/webm", ogg: "audio/ogg", oga: "audio/ogg", mp3: "audio/mpeg",
  wav: "audio/wav", m4a: "audio/mp4", flac: "audio/flac"};
function setAudio(f, label) {
  sttFile = f; $("sttSrc").textContent = label;
  $("sttAudio").src = URL.createObjectURL(f); $("sttAudio").hidden = false; say("sttMsg", "");
}
$("sttFile").onchange = e => {
  let f = e.target.files[0]; if (!f) return;
  let type = f.type.replace(/^video\//, "audio/");
  if (!type.startsWith("audio/")) type = EXT_TYPES[(f.name.split(".").pop() || "").toLowerCase()] || "";
  if (!type) { say("sttMsg", "Unsupported file type – please choose an audio file."); return; }
  if (f.size > 25 * MB) { say("sttMsg", "Audio file is larger than 25 MB."); return; }
  if (type !== f.type) f = new File([f], f.name, {type});
  setAudio(f, f.name);
};
$("recBtn").onclick = async () => {
  if (rec && rec.state === "recording") { rec.stop(); return; }
  if (!navigator.mediaDevices || !window.MediaRecorder) {
    say("sttMsg", "Recording needs HTTPS (or localhost) and a modern browser."); return;
  }
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({audio: true}); }
  catch (e) { say("sttMsg", "Microphone not available: " + e.message); return; }
  const mime = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/webm", "audio/mp4"]
    .find(t => MediaRecorder.isTypeSupported(t)) || "";
  rec = new MediaRecorder(stream, mime ? {mimeType: mime} : {});
  const parts = [];
  rec.ondataavailable = e => { if (e.data.size) parts.push(e.data); };
  rec.onstop = () => {
    stream.getTracks().forEach(t => t.stop()); clearInterval(recTimer);
    const type = (rec.mimeType || mime || "audio/webm").split(";")[0].replace(/^video\//, "audio/");
    const ext = type.includes("ogg") ? "ogg" : type.includes("mp4") ? "m4a" : "webm";
    setAudio(new File(parts, "recording." + ext, {type}), "Recording (" + $("recTime").textContent + ")");
    $("recBtn").textContent = "● Record"; $("recInfo").hidden = true;
  };
  const t0 = Date.now();
  recTimer = setInterval(() => {
    const s = Math.floor((Date.now() - t0) / 1000);
    $("recTime").textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    if (s >= 300 && rec.state === "recording") rec.stop();
  }, 250);
  $("recTime").textContent = "0:00"; rec.start(1000);
  $("recBtn").textContent = "■ Stop"; $("recInfo").hidden = false; say("sttMsg", "");
};
$("sttGo").onclick = async () => {
  if (!sttFile) { say("sttMsg", "Upload or record audio first."); return; }
  const fd = new FormData();
  fd.append("audio", sttFile); fd.append("language", $("sttLang").value); fd.append("task", $("sttTask").value);
  $("sttGo").disabled = true; say("sttMsg", "Transcribing…", "warn"); $("sttSegs").replaceChildren();
  try {
    const r = await api("api/stt", {method: "POST", body: fd});
    $("sttOut").textContent = r.text || "(no speech detected)";
    $("sttMeta").textContent = `${r.duration} s audio · ${r.seconds} s processing · ${r.task} · ${r.language}`;
    $("sttSegs").replaceChildren(...(r.chunks || []).map(c => el("div", {},
      el("b", {text: `${c.start ?? "?"}–${c.end ?? "?"} s`}), c.text)));
    say("sttMsg", "");
  } catch (e) { say("sttMsg", e.message, e.status === 409 ? "warn" : "err"); }
  $("sttGo").disabled = false;
};
$("sttCopy").onclick = () => navigator.clipboard && navigator.clipboard.writeText($("sttOut").textContent);

/* ---------- Vision ---------- */
let visFile = null, visTask = "caption";
$("visFile").onchange = e => pickImage(e.target, "visPrev", "visMsg", f => visFile = f);
document.querySelectorAll("#visTasks .chip").forEach(c => c.onclick = () => {
  visTask = c.dataset.task; document.querySelectorAll("#visTasks .chip").forEach(x => x.classList.toggle("sel", x === c));
});
$("visGo").onclick = async () => {
  if (!visFile) { say("visMsg", "Choose an image first."); return; }
  const fd = new FormData(); fd.append("image", visFile); fd.append("task", visTask);
  $("visGo").disabled = true; say("visMsg", "");
  $("visOut").textContent = "…"; $("visLabels").replaceChildren(); $("visdl").replaceChildren();
  if (visTask === "od") spinner($("visStage"));
  try {
    const r = await api("api/vision", {method: "POST", body: fd});
    $("visOut").textContent = r.text || "(nothing found)";
    $("visMeta").textContent = `${r.seconds} s · ${r.task} · ${r.model}`;
    if (r.image) { showImg($("visStage"), r.image, "detections"); dlLink("visdl", r.image, "detections.png"); }
    else $("visStage").textContent = "Annotated image appears here (object detection)";
    (r.objects || []).forEach(o => $("visLabels").append(el("span", {class: "chip", text: o.label, title: o.box.join(", ")})));
  } catch (e) {
    $("visOut").textContent = ""; $("visStage").textContent = "–"; say("visMsg", e.message, e.status === 409 ? "warn" : "err"); }
  $("visGo").disabled = false;
};

/* ---------- GPU panel ---------- */
function stat(id, text, pct) {
  $(id).textContent = text;
  const b = $(id + "Bar"); if (b) b.style.width = Math.max(0, Math.min(100, pct || 0)) + "%";
}
async function refreshGpu() {
  let d; try { d = await api("api/gpu"); } catch (e) { return; }
  const g = d.gpus[0];
  $("gpuNone").hidden = !!g; $("gpuStats").hidden = !g;
  $("gpuNone").textContent = "No NVIDIA GPU visible" + (d.reason ? " (" + d.reason + ")" : "") +
    (d.stub ? " – running with STUB_MODELS=1." : ".");
  $("gpuName").textContent = g ? "· " + g.name : "";
  if (g) {
    stat("gUtil", g.util_pct != null ? g.util_pct + " %" : "–", g.util_pct);
    stat("gMem", g.vram_used_gb != null ? `${g.vram_used_gb} / ${g.vram_total_gb} GB` : "–", 100 * g.vram_used_gb / g.vram_total_gb);
    stat("gTemp", g.temp_c != null ? g.temp_c + " °C" : "–", g.temp_c);
    stat("gPower", g.power_w != null ? `${g.power_w} / ${g.power_limit_w} W` : "–", 100 * g.power_w / g.power_limit_w);
    stat("gClock", g.sm_clock_mhz != null ? g.sm_clock_mhz + " MHz" : "–", 100 * g.sm_clock_mhz / g.sm_clock_max_mhz);
    stat("gMClock", g.mem_clock_mhz != null ? g.mem_clock_mhz + " MHz" : "–");
    $("gTorch").textContent = d.torch ? `PyTorch: ${d.torch.allocated_gb} GB allocated, ${d.torch.reserved_gb} GB reserved` : "";
  }
  $("modelRows").replaceChildren(...d.models.map(m => {
    const btn = m.status === "ready"
      ? el("button", {class: "ghost danger", text: "Unload", onclick: () => modelAction(m.name, "unload")})
      : (m.status === "loading" ? el("span", {class: "meta", text: m.progress || "loading…"})
        : el("button", {class: "ghost", text: m.status === "error" ? "Retry" : "Load", onclick: () => modelAction(m.name, "load")}));
    if (m.in_use) btn.disabled = true;
    const st = el("td", {}, el("span", {class: "dot " + (DOT[m.status] || "")}),
      (LABEL[m.status] || m.status).split(" – ")[0] + (m.in_use ? " (running)" : ""));
    if (m.error) st.title = m.error;
    return el("tr", {},
      el("td", {}, el("b", {text: m.name}), el("div", {class: "meta", text: m.variant || m.model_id})), st,
      el("td", {text: (m.vram_gb != null ? m.vram_gb + " GB" : "–") + " / ~" + m.est_gb + " GB"}),
      el("td", {text: fmtS(m.load_seconds)}), el("td", {text: ago(m.last_used)}), el("td", {}, btn));
  }));
  $("envInfo").replaceChildren(...[["Device", d.device], ["Stub models", d.stub ? "yes" : "no"],
    ["HF token configured", d.hf_token_configured ? "yes (" + d.hf_token_source + ")" : "no"], ["Driver", d.driver || "–"],
    ["GPU job", d.busy ? d.busy + " (" + ago(d.busy_since).replace(" ago", "") + ")" : "idle"], ["Build", d.version]]
    .flatMap(([k, v]) => [el("dt", {text: k}), el("dd", {text: v})]));
}
async function modelAction(name, action) {
  say("modelMsg", "");
  try { await api(`api/models/${encodeURIComponent(name)}/${action}`, {method: "POST"}); }
  catch (e) { say("modelMsg", e.message); }
  refreshGpu(); refreshStatus();
}
setInterval(() => { if (!$("tab-gpu").hidden) refreshGpu(); }, 2000);
$("benchGo").onclick = async () => {
  $("benchGo").disabled = true; say("benchMsg", "Running… (CPU part takes up to ~4 s)", "warn"); $("benchOut").replaceChildren();
  try {
    const r = await api("api/benchmark", {method: "POST"});
    const rows = [[`CPU (${r.cpu.backend}, ${r.cpu.threads} threads, ${r.cpu.reps}×)`, r.cpu]];
    if (r.gpu.available) rows.push(["GPU fp32", r.gpu.fp32], ["GPU fp16", r.gpu.fp16]);
    const max = Math.max(...rows.map(x => x[1].gflops));
    $("benchOut").replaceChildren(el("table", {}, el("tbody", {}, ...rows.map(([k, v]) => el("tr", {},
      el("td", {text: k}), el("td", {text: v.ms_per_matmul + " ms"}), el("td", {text: v.gflops + " GFLOPS"}),
      el("td", {style: "width:35%"}, el("div", {class: "bar"}, el("i", {style: `width:${Math.max(1, 100 * v.gflops / max)}%`}))))))));
    say("benchMsg", r.gpu.available ? `GPU is ${r.gpu.speedup_fp32}× (fp32) / ${r.gpu.speedup_fp16}× (fp16) faster than the CPU.`
      : "GPU part skipped: " + r.gpu.reason, r.gpu.available ? "" : "warn");
  } catch (e) { say("benchMsg", e.message); }
  $("benchGo").disabled = false;
};

/* ---------- GPU slicing ---------- */
const SL_COLORS = ["#76b900", "#38bdf8", "#fbbf24", "#f472b6", "#a78bfa", "#f87171", "#34d399", "#fb923c"];
let slColor = {};
function sbar(id, parts, total, unit) {
  const used = parts.reduce((a, p) => a + (p.v || 0), 0);
  const spans = parts.map(p => el("span", {style: `width:${100 * (p.v || 0) / total}%;background:${p.c}`,
    title: `${p.name}: ${p.v} ${unit}`, text: `${p.name} ${p.v} ${unit}`}));
  if (used < total) spans.push(el("span", {class: "free", style: `width:${100 * (total - used) / total}%`,
    text: `free ${+(total - used).toFixed(2)} ${unit}`}));
  $(id).replaceChildren(...spans);
}
function fmtBench(b) { return b ? `${b.tflops} TFLOPS (${ago(b.at)})` : "–"; }
function fmtOom(o) {
  if (!o) return "";
  if (!o.limit_hit) return `⚠ not limited: ${o.allocated_gb} GiB allocated (cap ${o.cap_gb})`;
  return (o.isolated ? "✔ limited at " : "⚠ stopped at ") + o.allocated_gb + " GiB";
}
async function refreshSlicing() {
  let d; try { d = await api("api/slicing"); } catch (e) { say("slMsg", e.message); return; }
  $("slOff").hidden = d.enabled; $("slOn").hidden = !d.enabled;
  if (!d.enabled) return;
  d.members.forEach((m, i) => slColor[m.name] = SL_COLORS[i % SL_COLORS.length]);
  const card = Math.max(d.card_gb, d.members.reduce((a, m) => a + (m.mem_gib || 0), 0));
  $("slCard").textContent = d.card_gb;
  sbar("slMemBar", d.members.map(m => ({name: m.name, v: m.mem_gib, c: slColor[m.name]})), card, "GiB");
  sbar("slCoreBar", d.members.map(m => ({name: m.name, v: m.core_percent, c: slColor[m.name]})), 100, "%");
  const me = d.members[0];
  $("slGpu").textContent = me.nvml ? "· " + me.nvml.name : (me.seen ? "· " + me.seen.device : "");
  $("slRows").replaceChildren(...d.members.map(m => {
    const seen = m.error ? el("span", {class: "meta", text: "unreachable: " + m.error})
      : (m.seen ? `${m.seen.free_gb} free / ${m.seen.total_gb} GiB` : "CUDA not initialised");
    let test = "";
    if (m.role === "worker" && !m.error) {
      const b = el("button", {class: "ghost", text: "Run", onclick: () => slOom(m.name, b)});
      if (m.busy) b.disabled = true;
      test = el("div", {}, b, el("div", {class: "meta", text: fmtOom(m.last_oom)}));
    } else if (m.role === "playground") test = el("span", {class: "meta", text: "keeps its models"});
    return el("tr", {},
      el("td", {}, el("span", {class: "swatch", style: "background:" + slColor[m.name]}), el("b", {text: m.name}),
        el("div", {class: "meta", text: m.role})),
      el("td", {}, el("div", {text: m.pod || "–"}), el("div", {class: "meta", text: m.node || ""})),
      el("td", {text: m.mem_gib != null ? m.mem_gib + " GiB" : "–"}), el("td", {}, seen),
      el("td", {text: m.core_percent != null ? m.core_percent + " %" : "–"}), el("td", {text: fmtBench(m.last_bench)}),
      el("td", {}, test));
  }));
  $("foot").textContent = "Build " + d.version + (d.stub ? " · STUB_MODELS=1 (simulated slices)" : "");
}
async function slOom(name, btn) {
  btn.disabled = true; say("slMsg", `Isolation test in '${name}' running…`, "warn");
  try {
    const r = await api(`api/slicing/oom/${encodeURIComponent(name)}`, {method: "POST"});
    if (r.limit_hit === undefined) say("slMsg", `${name}: ${r.error || "no result"}`);
    else say("slMsg", r.isolated
      ? `${name}: the driver refused more memory at ${r.allocated_gb} GiB (slice ${r.configured_gb} GiB) – other pods were not affected.`
      : `${name}: allocated ${r.allocated_gb} GiB with a ${r.configured_gb} GiB slice – the VRAM limit is not enforced.`,
      r.isolated ? "" : "warn");
  } catch (e) { say("slMsg", e.message); }
  btn.disabled = false; refreshSlicing();
}
$("slBench").onclick = async () => {
  $("slBench").disabled = true; say("slBenchMsg", "Running on all slices (~6 s, first run initialises CUDA in the workers)…", "warn");
  $("slBenchOut").replaceChildren();
  try {
    const r = await api("api/slicing/bench", {method: "POST"});
    const ok = r.results.filter(x => x.tflops != null);
    const sum = ok.reduce((a, x) => a + x.tflops, 0) || 1, max = Math.max(1, ...ok.map(x => x.tflops));
    const cores = ok.reduce((a, x) => a + (x.core_percent || 0), 0) || 1;
    $("slBenchOut").replaceChildren(el("table", {}, el("thead", {}, el("tr", {}, ...["Slice", "Compute share", "TFLOPS",
      "Measured share", ""].map(t => el("th", {text: t})))), el("tbody", {}, ...r.results.map(x => el("tr", {},
      el("td", {}, el("span", {class: "swatch", style: "background:" + (slColor[x.name] || "#888")}), x.name),
      el("td", {text: x.core_percent != null ? `${x.core_percent} % (${Math.round(100 * x.core_percent / cores)} % of used)` : "–"}),
      el("td", {text: x.tflops != null ? x.tflops : "error: " + x.error}),
      el("td", {text: x.tflops != null ? Math.round(100 * x.tflops / sum) + " %" : "–"}),
      el("td", {style: "width:30%"}, el("div", {class: "bar"}, el("i", {style: `width:${100 * (x.tflops || 0) / max}%;` +
        `background:${slColor[x.name] || "#888"}`}))))))));
    say("slBenchMsg", `Together ${sum.toFixed(1)} TFLOPS. With enforced compute limits the measured share follows the
      configured share.`.replace(/\s+/g, " "), "");
  } catch (e) { say("slBenchMsg", e.message); }
  $("slBench").disabled = false; refreshSlicing();
};
setInterval(() => { if (!$("tab-slicing").hidden) refreshSlicing(); }, 3000);

showTab(location.hash.slice(1)); refreshStatus(); gallery();
</script>
</body>
</html>
"""
