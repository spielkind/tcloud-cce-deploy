import os
import re

import requests
from flask import Flask, redirect, render_template_string, request, url_for

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "dev")
BAO_ADDR = os.environ.get("BAO_ADDR", "http://openbao.openbao.svc:8200")
BAO_ROLE = os.environ.get("BAO_ROLE", "demo-app")
SECRET_PATH = os.environ.get("BAO_SECRET_PATH", "demo/config")
SECRET_FILE = os.environ.get("BAO_SECRET_FILE", "/vault/secrets/config")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
KEY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
HISTORY_LIMIT = 10


class BaoError(Exception):
    pass


def login():
    """Login to OpenBao via Kubernetes auth and return a client token."""
    with open(SA_TOKEN_PATH) as f:
        jwt = f.read()
    r = requests.post(f"{BAO_ADDR}/v1/auth/kubernetes/login",
                      json={"role": BAO_ROLE, "jwt": jwt}, timeout=10)
    if r.status_code != 200:
        raise BaoError(f"login failed (HTTP {r.status_code})")
    return r.json()["auth"]["client_token"]


def bao(method, path, token, **kwargs):
    r = requests.request(method, f"{BAO_ADDR}/v1/{path}",
                         headers={"Authorization": f"Bearer {token}"}, timeout=10, **kwargs)
    if r.status_code >= 400:
        errors = r.json().get("errors", []) if r.content else []
        raise BaoError(f"{method} {path}: HTTP {r.status_code} {'; '.join(errors)}".strip())
    return r.json() if r.content else {}


def read_secret(token, version=None):
    params = {"version": version} if version else None
    data = bao("GET", f"kv/data/{SECRET_PATH}", token, params=params)["data"]
    return data.get("data") or {}, data.get("metadata") or {}


def read_history(token):
    meta = bao("GET", f"kv/metadata/{SECRET_PATH}", token)["data"]
    versions = [
        {"version": int(v), **info}
        for v, info in (meta.get("versions") or {}).items()
    ]
    versions.sort(key=lambda v: v["version"], reverse=True)
    return versions[:HISTORY_LIMIT], meta.get("current_version", 0)


def write_secret(token, data, cas):
    """Write a new version; check-and-set rejects concurrent updates."""
    return bao("POST", f"kv/data/{SECRET_PATH}", token,
               json={"options": {"cas": cas}, "data": data})["data"]["version"]


def read_injected():
    """Read secrets from the file rendered by the OpenBao Agent sidecar."""
    secrets = {}
    try:
        with open(SECRET_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    secrets[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return secrets


def back(msg, kind="ok"):
    return redirect(url_for("index", msg=msg, type=kind))


TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenBao Demo</title>
  <style>
    :root {
      --bg: #0b1020; --panel: #121a2f; --panel-2: #172241; --line: #24304f;
      --text: #e6e9f2; --muted: #8b93a7; --accent: #ffb020; --accent-2: #ff8a00;
      --ok: #34d399; --warn: #fbbf24; --err: #f87171; --info: #60a5fa;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           color: var(--text); min-height: 100vh;
           background: radial-gradient(1200px 600px at 10% -10%, #1d2a55 0%, transparent 60%),
                       radial-gradient(900px 500px at 110% 10%, #3a2108 0%, transparent 55%), var(--bg); }
    code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .wrap { max-width: 980px; margin: 0 auto; padding: 32px 20px 48px; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 24px; }
    .brand { display: flex; align-items: center; gap: 14px; }
    .logo { width: 44px; height: 44px; border-radius: 12px; display: grid; place-items: center;
            background: linear-gradient(135deg, var(--accent), var(--accent-2)); color: #1a1205;
            font-weight: 800; font-size: 20px; box-shadow: 0 8px 24px rgba(255,138,0,.35); }
    h1 { font-size: 22px; letter-spacing: .2px; }
    .sub { color: var(--muted); font-size: 13px; }
    .pill { display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 999px;
            background: var(--panel); border: 1px solid var(--line); font-size: 12px; color: var(--muted); }
    .dot { width: 8px; height: 8px; border-radius: 50%; }
    .dot.ok { background: var(--ok); box-shadow: 0 0 10px var(--ok); }
    .dot.warn { background: var(--warn); box-shadow: 0 0 10px var(--warn); }
    .dot.err { background: var(--err); box-shadow: 0 0 10px var(--err); }
    .grid { display: grid; grid-template-columns: 1.6fr 1fr; gap: 20px; }
    @media (max-width: 820px) { .grid { grid-template-columns: 1fr; } header { flex-direction: column; align-items: flex-start; } }
    .card { background: linear-gradient(180deg, var(--panel), #0f1629); border: 1px solid var(--line);
            border-radius: 16px; padding: 22px; box-shadow: 0 10px 30px rgba(0,0,0,.25); }
    .card + .card { margin-top: 20px; }
    .card h2 { font-size: 15px; display: flex; align-items: center; gap: 10px; margin-bottom: 4px; }
    .hint { color: var(--muted); font-size: 12px; margin-bottom: 16px; }
    .badge { font-size: 11px; padding: 2px 8px; border-radius: 6px; background: var(--panel-2);
             border: 1px solid var(--line); color: var(--accent); font-weight: 600; }
    table { width: 100%; border-collapse: collapse; }
    th { text-align: left; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .8px;
         color: var(--muted); padding: 8px 10px; border-bottom: 1px solid var(--line); }
    td { padding: 10px; border-bottom: 1px solid #1b2542; vertical-align: middle; word-break: break-all; }
    tr:last-child td { border-bottom: none; }
    .key { color: var(--info); }
    .val { color: var(--text); }
    .state { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); white-space: nowrap; }
    .missing { color: var(--muted); font-style: italic; }
    input[type=text] { width: 100%; background: #0c1326; border: 1px solid var(--line); border-radius: 10px;
                       color: var(--text); padding: 9px 12px; font: 13px ui-monospace, Menlo, monospace;
                       transition: border-color .15s, box-shadow .15s; }
    input[type=text]:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(255,176,32,.15); }
    input[type=checkbox] { accent-color: var(--err); width: 16px; height: 16px; }
    .new td { padding-top: 14px; }
    button { border: 0; border-radius: 10px; padding: 10px 18px; font-weight: 700; font-size: 13px; cursor: pointer;
             color: #1a1205; background: linear-gradient(135deg, var(--accent), var(--accent-2));
             box-shadow: 0 6px 18px rgba(255,138,0,.25); transition: transform .1s, filter .15s; }
    button:hover { filter: brightness(1.08); } button:active { transform: translateY(1px); }
    button.ghost { background: var(--panel-2); color: var(--text); border: 1px solid var(--line);
                   box-shadow: none; padding: 6px 12px; font-weight: 600; }
    .actions { display: flex; justify-content: flex-end; margin-top: 16px; }
    .flash { padding: 12px 16px; border-radius: 12px; margin-bottom: 20px; font-size: 13px; border: 1px solid; }
    .flash.ok { background: rgba(52,211,153,.08); border-color: rgba(52,211,153,.35); color: var(--ok); }
    .flash.err { background: rgba(248,113,113,.08); border-color: rgba(248,113,113,.35); color: var(--err); }
    .timeline { list-style: none; position: relative; }
    .timeline:before { content: ""; position: absolute; left: 7px; top: 6px; bottom: 6px; width: 2px; background: var(--line); }
    .timeline li { position: relative; padding: 0 0 16px 28px; }
    .timeline li:before { content: ""; position: absolute; left: 0; top: 4px; width: 16px; height: 16px; border-radius: 50%;
                          background: var(--panel-2); border: 2px solid var(--line); }
    .timeline li.current:before { border-color: var(--accent); background: var(--accent); box-shadow: 0 0 12px rgba(255,176,32,.6); }
    .timeline li.gone { opacity: .5; }
    .row { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
    .when { color: var(--muted); font-size: 12px; }
    .flow { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12px; color: var(--muted); }
    .flow span { padding: 4px 10px; border-radius: 8px; background: var(--panel-2); border: 1px solid var(--line); color: var(--text); }
    footer { margin-top: 28px; text-align: center; color: var(--muted); font-size: 12px; }
  </style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand">
      <div class="logo">B</div>
      <div>
        <h1>OpenBao Demo</h1>
        <div class="sub">Secrets on T-Cloud CCE · Agent sidecar for reads · KV v2 API for writes</div>
      </div>
    </div>
    {% set in_sync = live and injected == live %}
    <div class="pill">
      <span class="dot {{ 'err' if error else ('ok' if in_sync else 'warn') }}"></span>
      {{ 'OpenBao unreachable' if error else ('Sidecar in sync' if in_sync else 'Sidecar catching up…') }}
    </div>
  </header>

  {% if flash_msg %}<div class="flash {{ flash_type }}">{{ flash_msg }}</div>{% endif %}
  {% if error %}<div class="flash err">{{ error }}</div>{% endif %}

  <div class="grid">
    <div>
      <section class="card">
        <h2>Secret <code>kv/{{ path }}</code>{% if meta.version %}<span class="badge">v{{ meta.version }}</span>{% endif %}</h2>
        <p class="hint">Live values come from the API; injected values from <code>/vault/secrets/config</code>,
          re-rendered by the sidecar every ~30s.</p>
        <table>
          <tr><th>Key</th><th>Live</th><th>Injected</th><th></th></tr>
          {% for key in keys %}
          {% set l, i = live.get(key), injected.get(key) %}
          <tr>
            <td class="mono key">{{ key }}</td>
            <td class="mono {{ 'val' if l is not none else 'missing' }}">{{ l if l is not none else 'removed' }}</td>
            <td class="mono {{ 'val' if i is not none else 'missing' }}">{{ i if i is not none else 'not yet' }}</td>
            <td><span class="state"><span class="dot {{ 'ok' if l == i else 'warn' }}"></span>
              {{ 'synced' if l == i else 'pending' }}</span></td>
          </tr>
          {% else %}
          <tr><td colspan="4" class="missing">No secret data yet.</td></tr>
          {% endfor %}
        </table>
      </section>

      {% if not error %}
      <section class="card">
        <h2>Edit secret</h2>
        <p class="hint">Saving creates a new version with check-and-set (<code>cas={{ meta.version or 0 }}</code>) —
          concurrent edits are rejected instead of overwritten.</p>
        <form method="POST" action="{{ url_for('update_secrets') }}">
          <input type="hidden" name="cas" value="{{ meta.version or 0 }}">
          <table>
            <tr><th style="width:30%">Key</th><th>Value</th><th style="width:60px">Delete</th></tr>
            {% for key, value in live.items() %}
            <tr>
              <td class="mono key">{{ key }}<input type="hidden" name="key" value="{{ key }}"></td>
              <td><input type="text" name="value" value="{{ value }}" aria-label="{{ key }}"></td>
              <td style="text-align:center"><input type="checkbox" name="delete" value="{{ key }}" aria-label="delete {{ key }}"></td>
            </tr>
            {% endfor %}
            <tr class="new">
              <td><input type="text" name="new_key" placeholder="new key" aria-label="new key"></td>
              <td><input type="text" name="new_value" placeholder="value" aria-label="new value"></td>
              <td></td>
            </tr>
          </table>
          <div class="actions"><button type="submit">Save new version</button></div>
        </form>
      </section>
      {% endif %}
    </div>

    <div>
      {% if not error %}
      <section class="card">
        <h2>Version history</h2>
        <p class="hint">Restore writes an old version as a new one.</p>
        <ul class="timeline">
          {% for v in history %}
          {% set gone = v.destroyed or v.deletion_time %}
          <li class="{{ 'current' if v.version == current }} {{ 'gone' if gone }}">
            <div class="row">
              <div>
                <strong>v{{ v.version }}</strong>
                {% if v.version == current %}<span class="badge">current</span>{% endif %}
                {% if gone %}<span class="badge">{{ 'destroyed' if v.destroyed else 'deleted' }}</span>{% endif %}
                <div class="when">{{ (v.created_time or '')[:19] | replace('T', ' ') }} UTC</div>
              </div>
              {% if v.version != current and not gone %}
              <form method="POST" action="{{ url_for('restore', version=v.version) }}">
                <input type="hidden" name="cas" value="{{ current }}">
                <button class="ghost" type="submit">Restore</button>
              </form>
              {% endif %}
            </div>
          </li>
          {% else %}
          <li class="when">No versions yet.</li>
          {% endfor %}
        </ul>
      </section>
      {% endif %}

      <section class="card">
        <h2>How it works</h2>
        <p class="hint">Pod ServiceAccount → Kubernetes auth → policy <code>demo-app</code></p>
        <div class="flow"><span>OpenBao</span>→<span>Agent sidecar</span>→<span>/vault/secrets/config</span>→<span>App</span></div>
      </section>
    </div>
  </div>

  <footer>Build {{ version }}</footer>
</div>
</body>
</html>
"""


@app.route("/")
def index():
    injected = read_injected()
    live, meta, history, current, error = {}, {}, [], 0, None
    try:
        token = login()
        live, meta = read_secret(token)
        history, current = read_history(token)
    except (BaoError, OSError, requests.RequestException) as e:
        error = f"OpenBao not reachable: {e}"
    keys = sorted(set(live) | set(injected))
    return render_template_string(
        TEMPLATE, path=SECRET_PATH, live=live, injected=injected, keys=keys, meta=meta,
        history=history, current=current, error=error, version=VERSION,
        flash_msg=request.args.get("msg"), flash_type=request.args.get("type", "ok"))


@app.route("/secrets", methods=["POST"])
def update_secrets():
    form = request.form
    deleted = set(form.getlist("delete"))
    data = {k: v.strip() for k, v in zip(form.getlist("key"), form.getlist("value")) if k not in deleted}
    new_key, new_value = form.get("new_key", "").strip(), form.get("new_value", "").strip()
    if new_key:
        if not KEY_PATTERN.match(new_key):
            return back("Invalid key: use 1-64 characters A-Z a-z 0-9 _ . -", "err")
        data[new_key] = new_value
    if any("\n" in v or "\r" in v for v in data.values()):
        return back("Values must be single-line", "err")
    try:
        version = write_secret(login(), data, int(form.get("cas", 0)))
    except (BaoError, OSError, ValueError, requests.RequestException) as e:
        return back(f"Save failed: {e}", "err")
    return back(f"Saved version {version}")


@app.route("/restore/<int:version>", methods=["POST"])
def restore(version):
    try:
        token = login()
        data, _ = read_secret(token, version)
        new_version = write_secret(token, data, int(request.form.get("cas", 0)))
    except (BaoError, OSError, ValueError, requests.RequestException) as e:
        return back(f"Restore failed: {e}", "err")
    return back(f"Restored v{version} as version {new_version}")


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
