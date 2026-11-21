import base64
import io
import os
import random
import threading
import time
from collections import deque
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

VERSION = os.environ.get("APP_VERSION", "dev")
MODEL_ID = os.environ.get("MODEL_ID", "stabilityai/sdxl-turbo")
DEVICE = os.environ.get("DEVICE", "cuda")
IMAGE_SIZE = int(os.environ.get("IMAGE_SIZE", "512"))
GALLERY_SIZE = 8

state = {"status": "loading", "error": None, "load_seconds": None, "gpu": None, "pipe": None}
gallery = deque(maxlen=GALLERY_SIZE)
gpu_lock = threading.Lock()


class GenerateRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=300)
    steps: int = Field(default=2, ge=1, le=4)
    seed: int | None = Field(default=None, ge=0, le=2**31 - 1)


def gpu_info():
    import torch

    if DEVICE != "cuda" or not torch.cuda.is_available():
        return {"name": "CPU", "memory_gb": None, "cuda": None}
    props = torch.cuda.get_device_properties(0)
    return {"name": props.name, "memory_gb": round(props.total_memory / 2**30, 1), "cuda": torch.version.cuda}


def load_pipeline():
    """Load the model in the background so the pod starts serving the UI immediately."""
    start = time.monotonic()
    try:
        import torch
        from diffusers import AutoPipelineForText2Image

        dtype = torch.float16 if DEVICE == "cuda" else torch.float32
        kwargs = {"torch_dtype": dtype}
        if DEVICE == "cuda":
            kwargs["variant"] = "fp16"
        pipe = AutoPipelineForText2Image.from_pretrained(MODEL_ID, **kwargs).to(DEVICE)
        pipe.set_progress_bar_config(disable=True)
        state.update(pipe=pipe, gpu=gpu_info(), status="ready", load_seconds=round(time.monotonic() - start, 1))
    except Exception as e:  # noqa: BLE001 - surface any load error in the UI
        state.update(status="error", error=f"{type(e).__name__}: {e}")


@asynccontextmanager
async def lifespan(_app):
    threading.Thread(target=load_pipeline, daemon=True).start()
    yield


app = FastAPI(title="GPU Image Demo", lifespan=lifespan)


def generate_image(req: GenerateRequest):
    import torch

    seed = req.seed if req.seed is not None else random.randint(0, 2**31 - 1)
    generator = torch.Generator(device=DEVICE).manual_seed(seed)
    with gpu_lock:
        start = time.monotonic()
        image = state["pipe"](
            prompt=req.prompt, num_inference_steps=req.steps, guidance_scale=0.0,
            width=IMAGE_SIZE, height=IMAGE_SIZE, generator=generator,
        ).images[0]
        seconds = round(time.monotonic() - start, 2)
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return {"image": base64.b64encode(buf.getvalue()).decode(), "seconds": seconds, "seed": seed,
            "steps": req.steps, "prompt": req.prompt}


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/readyz")
def readyz():
    if state["status"] != "ready":
        return JSONResponse({"status": state["status"]}, status_code=503)
    return {"status": "ready"}


@app.get("/api/status")
def status():
    return {"status": state["status"], "error": state["error"], "model": MODEL_ID, "gpu": state["gpu"],
            "load_seconds": state["load_seconds"], "version": VERSION, "size": IMAGE_SIZE}


@app.get("/api/gallery")
def get_gallery():
    return list(gallery)


@app.post("/api/generate")
def generate(req: GenerateRequest):
    if state["status"] != "ready":
        raise HTTPException(503, f"Model is {state['status']}")
    result = generate_image(req)
    gallery.appendleft(result)
    return result


@app.get("/", response_class=HTMLResponse)
def index():
    return PAGE


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GPU Image Demo</title>
<style>
  :root { --bg:#0b1020; --panel:#121a2f; --panel-2:#172241; --line:#24304f; --text:#e6e9f2; --muted:#8b93a7;
          --accent:#76b900; --accent-2:#4c8c00; --ok:#34d399; --warn:#fbbf24; --err:#f87171; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; color:var(--text); min-height:100vh;
         background: radial-gradient(1200px 600px at 10% -10%, #1d2a55 0%, transparent 60%),
                     radial-gradient(900px 500px at 110% 10%, #1f3a08 0%, transparent 55%), var(--bg); }
  .wrap { max-width:1080px; margin:0 auto; padding:32px 20px 48px; }
  header { display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom:24px; flex-wrap:wrap; }
  .brand { display:flex; align-items:center; gap:14px; }
  .logo { width:44px; height:44px; border-radius:12px; display:grid; place-items:center; font-weight:800; font-size:18px;
          background:linear-gradient(135deg,var(--accent),var(--accent-2)); color:#0b1400; box-shadow:0 8px 24px rgba(118,185,0,.35); }
  h1 { font-size:22px; } .sub { color:var(--muted); font-size:13px; }
  .pill { display:inline-flex; align-items:center; gap:8px; padding:6px 12px; border-radius:999px; background:var(--panel);
          border:1px solid var(--line); font-size:12px; color:var(--muted); }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--warn); box-shadow:0 0 10px var(--warn); }
  .dot.ok { background:var(--ok); box-shadow:0 0 10px var(--ok); } .dot.err { background:var(--err); box-shadow:0 0 10px var(--err); }
  .grid { display:grid; grid-template-columns:1.3fr 1fr; gap:20px; }
  @media (max-width:860px) { .grid { grid-template-columns:1fr; } }
  .card { background:linear-gradient(180deg,var(--panel),#0f1629); border:1px solid var(--line); border-radius:16px; padding:22px;
          box-shadow:0 10px 30px rgba(0,0,0,.25); }
  .card + .card { margin-top:20px; }
  h2 { font-size:15px; margin-bottom:12px; }
  textarea { width:100%; min-height:90px; resize:vertical; background:#0c1326; border:1px solid var(--line); border-radius:12px;
             color:var(--text); padding:12px; font:14px/1.4 inherit; }
  textarea:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px rgba(118,185,0,.15); }
  .row { display:flex; gap:12px; align-items:center; margin-top:14px; flex-wrap:wrap; }
  label { color:var(--muted); font-size:12px; } input[type=number] { width:110px; } input[type=range] { accent-color:var(--accent); }
  input[type=number] { background:#0c1326; border:1px solid var(--line); border-radius:10px; color:var(--text); padding:7px 10px; }
  button { margin-left:auto; border:0; border-radius:10px; padding:10px 20px; font-weight:700; cursor:pointer; color:#0b1400;
           background:linear-gradient(135deg,var(--accent),var(--accent-2)); box-shadow:0 6px 18px rgba(118,185,0,.25); }
  button:disabled { opacity:.5; cursor:wait; }
  .stage { aspect-ratio:1; border-radius:14px; border:1px dashed var(--line); display:grid; place-items:center; overflow:hidden;
           background:#0c1326; color:var(--muted); margin-top:16px; }
  .stage img { width:100%; height:100%; object-fit:cover; }
  .meta { color:var(--muted); font-size:12px; margin-top:8px; min-height:18px; }
  .chips { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
  .chip { font-size:12px; padding:4px 10px; border-radius:999px; background:var(--panel-2); border:1px solid var(--line); cursor:pointer; }
  dl { display:grid; grid-template-columns:auto 1fr; gap:6px 14px; font-size:13px; } dt { color:var(--muted); }
  .gallery { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }
  .gallery img { width:100%; border-radius:10px; border:1px solid var(--line); cursor:pointer; }
  .spinner { width:28px; height:28px; border:3px solid var(--line); border-top-color:var(--accent);
             border-radius:50%; animation:spin 1s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  footer { margin-top:28px; text-align:center; color:var(--muted); font-size:12px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand"><div class="logo">AI</div>
      <div><h1>GPU Image Demo</h1><div class="sub">Text-to-image on a T-Cloud CCE GPU node · SDXL-Turbo via diffusers</div></div>
    </div>
    <div class="pill"><span class="dot" id="dot"></span><span id="state">Connecting…</span></div>
  </header>
  <div class="grid">
    <section class="card">
      <h2>Prompt</h2>
      <textarea id="prompt" maxlength="300">A cinematic photo of a magenta cloud server rack in a misty forest, golden hour</textarea>
      <div class="chips" id="chips"></div>
      <div class="row">
        <label>Steps <input type="range" id="steps" min="1" max="4" value="2"> <span id="stepsv">2</span></label>
        <label>Seed <input type="number" id="seed" placeholder="random" min="0"></label>
        <button id="go" disabled>Generate</button>
      </div>
      <div class="stage" id="stage">Your image appears here</div>
      <div class="meta" id="meta"></div>
    </section>
    <div>
      <section class="card"><h2>Node</h2><dl id="info"><dt>Status</dt><dd>…</dd></dl></section>
      <section class="card"><h2>Recent</h2><div class="gallery" id="gallery"></div></section>
    </div>
  </div>
  <footer id="foot"></footer>
</div>
<script>
const $ = id => document.getElementById(id);
const ideas = ["Isometric data center made of LEGO", "Watercolor of a robot sorting magenta cubes",
               "Neon city at night, rain, 35mm photo", "A friendly octopus operating a GPU cluster"];
ideas.forEach(t => { const c = document.createElement("span"); c.className = "chip"; c.textContent = t;
  c.onclick = () => $("prompt").value = t; $("chips").appendChild(c); });
$("steps").oninput = e => $("stepsv").textContent = e.target.value;
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
function show(r) {
  $("stage").innerHTML = `<img alt="${esc(r.prompt)}" src="data:image/png;base64,${r.image}">`;
  $("meta").textContent = `${r.seconds}s · ${r.steps} step(s) · seed ${r.seed}`;
}
async function status() {
  const s = await (await fetch("api/status")).json();
  const label = {ready: "GPU ready", loading: "Loading model…", error: "Model failed to load"}[s.status];
  $("state").textContent = label; $("dot").className = "dot " + ({ready: "ok", error: "err"}[s.status] || "");
  $("go").disabled = s.status !== "ready";
  const g = s.gpu || {};
  $("info").innerHTML = [["Status", label + (s.error ? ` — ${s.error}` : "")], ["GPU", g.name || "—"],
    ["VRAM", g.memory_gb ? g.memory_gb + " GB" : "—"], ["CUDA", g.cuda || "—"], ["Model", s.model],
    ["Load time", s.load_seconds ? s.load_seconds + " s" : "—"], ["Size", `${s.size}×${s.size}`]]
    .map(([k, v]) => `<dt>${k}</dt><dd>${esc(v)}</dd>`).join("");
  $("foot").textContent = "Build " + s.version;
  if (s.status === "loading") setTimeout(status, 3000);
}
async function gallery() {
  const items = await (await fetch("api/gallery")).json();
  $("gallery").innerHTML = "";
  items.forEach(r => { const i = document.createElement("img"); i.src = "data:image/png;base64," + r.image;
    i.title = r.prompt; i.onclick = () => show(r); $("gallery").appendChild(i); });
}
$("go").onclick = async () => {
  $("go").disabled = true; $("stage").innerHTML = '<div class="spinner"></div>'; $("meta").textContent = "";
  const body = {prompt: $("prompt").value, steps: +$("steps").value};
  if ($("seed").value !== "") body.seed = +$("seed").value;
  try {
    const r = await fetch("api/generate", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
    const d = await r.json();
    if (!r.ok) throw new Error(typeof d.detail === "string" ? d.detail : "Invalid input");
    show(d); gallery();
  } catch (e) { $("stage").textContent = "Error: " + e.message; }
  $("go").disabled = false;
};
status(); gallery();
</script>
</body>
</html>
"""
