import json
import os
import re
import secrets
import threading
import time

import requests
from flask import Flask, abort, redirect, render_template_string, request, session, url_for

app = Flask(__name__)
# Per-process key: only protects the CSRF token in the session cookie (single gunicorn worker).
app.config.update(SECRET_KEY=os.environ.get("FLASK_SECRET_KEY") or secrets.token_hex(32),
                  SESSION_COOKIE_SAMESITE="Strict", SESSION_COOKIE_HTTPONLY=True)

VERSION = os.environ.get("APP_VERSION", "dev")
BAO_ADDR = os.environ.get("BAO_ADDR", "http://openbao.openbao.svc:8200")
BAO_ROLE = os.environ.get("BAO_ROLE", "demo-app")
SECRET_PATH = os.environ.get("BAO_SECRET_PATH", "demo/config")
SECRET_FILE = os.environ.get("BAO_SECRET_FILE", "/vault/secrets/config")
RENDER_INTERVAL = int(os.environ.get("BAO_RENDER_INTERVAL", "30"))
ACCESS_MODE = os.environ.get("BAO_ACCESS_MODE", "both")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
KEY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
HISTORY_LIMIT = 10
TOKEN_RENEW_MARGIN = 60

AGENT_ENABLED = ACCESS_MODE in ("agent", "both")
API_ENABLED = ACCESS_MODE in ("api", "both")


class BaoError(Exception):
    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status


_token = {"value": None, "expires": 0.0, "ttl": 0}
_token_lock = threading.Lock()


def login(force=False):
    """Kubernetes auth login; the client token is cached until shortly before it expires."""
    with _token_lock:
        if not force and _token["value"] and time.time() < _token["expires"] - TOKEN_RENEW_MARGIN:
            return _token["value"]
        with open(SA_TOKEN_PATH) as f:
            jwt = f.read()
        r = requests.post(f"{BAO_ADDR}/v1/auth/kubernetes/login",
                          json={"role": BAO_ROLE, "jwt": jwt}, timeout=10)
        if r.status_code != 200:
            raise BaoError(f"login failed (HTTP {r.status_code})", r.status_code)
        auth = r.json()["auth"]
        _token.update(value=auth["client_token"], ttl=auth.get("lease_duration", 0),
                      expires=time.time() + auth.get("lease_duration", 0))
        return _token["value"]


def token_info():
    if not _token["value"]:
        return None
    return {"ttl": _token["ttl"], "remaining": max(0, int(_token["expires"] - time.time()))}


def bao(method, path, **kwargs):
    """Call the OpenBao API; on 403 the cached token is refreshed once."""
    for attempt in (0, 1):
        token = login(force=attempt == 1)
        r = requests.request(method, f"{BAO_ADDR}/v1/{path}",
                             headers={"X-Vault-Token": token}, timeout=10, **kwargs)
        if r.status_code == 403 and attempt == 0:
            continue
        if r.status_code >= 400:
            errors = r.json().get("errors", []) if r.content else []
            raise BaoError(f"{method} {path}: HTTP {r.status_code} {'; '.join(errors)}".strip(), r.status_code)
        return r.json() if r.content else {}
    raise BaoError(f"{method} {path}: forbidden", 403)


def read_secret(version=None):
    params = {"version": version} if version else None
    data = bao("GET", f"kv/data/{SECRET_PATH}", params=params)["data"]
    return data.get("data") or {}, data.get("metadata") or {}


def read_history():
    meta = bao("GET", f"kv/metadata/{SECRET_PATH}")["data"]
    versions = [{"version": int(v), **info} for v, info in (meta.get("versions") or {}).items()]
    versions.sort(key=lambda v: v["version"], reverse=True)
    return versions[:HISTORY_LIMIT], meta.get("current_version", 0)


def write_secret(data, cas):
    """Write a new version; check-and-set rejects concurrent updates."""
    return bao("POST", f"kv/data/{SECRET_PATH}",
               json={"options": {"cas": cas}, "data": data})["data"]["version"]


def read_injected():
    """Read the file rendered by the OpenBao Agent sidecar (JSON; KEY=VALUE as fallback)."""
    try:
        with open(SECRET_FILE) as f:
            raw = f.read()
        mtime = os.path.getmtime(SECRET_FILE)
    except FileNotFoundError:
        return None, None
    try:
        data = json.loads(raw) if raw.strip() else {}
        values = {str(k): v if isinstance(v, str) else json.dumps(v) for k, v in data.items()}
    except (ValueError, AttributeError):
        values = {}
        for line in raw.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    return values, mtime


def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


@app.before_request
def check_csrf():
    if request.method == "POST":
        sent = request.form.get("csrf", "")
        if not sent or not secrets.compare_digest(sent, session.get("csrf", "")):
            abort(400, "invalid or missing CSRF token - reload the page")


def back(msg, kind="ok", saved=None):
    args = {"msg": msg, "type": kind}
    if saved:
        args.update(saved=saved, at=int(time.time()))
    return redirect(url_for("index", **args))


def timed(fn, *args):
    start = time.perf_counter()
    result = fn(*args)
    return result, round((time.perf_counter() - start) * 1000, 1)


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
      --way1: #c084fc; --way2: #60a5fa;
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
    .two { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 20px; }
    @media (max-width: 820px) { .two { grid-template-columns: 1fr; } }
    .section-gap { margin-top: 20px; }
    .two > *, .grid > * { min-width: 0; }
    .two .card + .card, .grid .card + .card { margin-top: 0; }
    .way1 { border-top: 3px solid var(--way1); } .way2 { border-top: 3px solid var(--way2); }
    .num { display: inline-grid; place-items: center; width: 22px; height: 22px; border-radius: 50%;
           font-size: 12px; font-weight: 800; color: #0b1020; }
    .num.w1 { background: var(--way1); } .num.w2 { background: var(--way2); }
    .facts { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; font-size: 12px; margin: 10px 0 14px; }
    .facts dt { color: var(--muted); } .facts dd { color: var(--text); word-break: break-all; }
    .pros { font-size: 12px; color: var(--muted); margin: 0 0 14px 16px; }
    .pros li { margin-bottom: 2px; } .pros b { color: var(--text); font-weight: 600; }
    pre { background: #0a1122; border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px;
          font: 11.5px/1.5 ui-monospace, Menlo, monospace; color: #c9d1e6; overflow-x: auto; margin-bottom: 14px; }
    .off { opacity: .45; }
    .disabled-note { color: var(--muted); font-style: italic; font-size: 12px; }
    .arch svg { width: 100%; height: auto; display: block; }
    .arch .mt { font-family: ui-monospace, Menlo, monospace; }
    .arch .n { font-size: 12px; font-weight: 800; text-anchor: middle; fill: #0b1020; }
    .arch text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    .flash.info { background: rgba(96,165,250,.08); border-color: rgba(96,165,250,.35); color: var(--info); }
  </style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand">
      <div class="logo">B</div>
      <div>
        <h1>OpenBao Demo</h1>
        <div class="sub">Two ways to consume a secret on T-Cloud CCE · mode <code>{{ access_mode }}</code></div>
      </div>
    </div>
    <div class="pill">
      {% if error %}<span class="dot err"></span>OpenBao API unreachable
      {% elif compare %}<span class="dot {{ 'ok' if in_sync else 'warn' }}"></span>
        {{- '① and ② in sync' if in_sync else 'Sidecar catching up…' }}
      {% else %}<span class="dot ok"></span>{{ 'Sidecar only' if agent_enabled else 'API only' }}{% endif %}
    </div>
  </header>

  {% if flash_msg %}<div class="flash {{ flash_type }}">{{ flash_msg }}</div>{% endif %}
  {% if error %}<div class="flash err">{{ error }}</div>{% endif %}
  {% if saved and compare %}
    {% if in_sync and rendered_after_save %}
    <div class="flash ok">① Sidecar picked up v{{ saved }} — the file now matches the API ({{ sync_latency }} s after saving).</div>
    {% elif not in_sync %}
    <div class="flash info" id="pending">② API already returns v{{ saved }}. ① The sidecar re-renders every {{ render_interval }} s —
      waiting for the file… <b id="elapsed">{{ since_save }}</b> s</div>
    {% endif %}
  {% endif %}

  <section class="card arch">
    <h2>Architecture</h2>
    <p class="hint">Both ways authenticate with the pod's ServiceAccount token (Kubernetes auth); OpenBao verifies it via TokenReview.</p>
    <svg viewBox="0 0 900 232" role="img" aria-label="Sidecar and API access to OpenBao">
      <defs>
        <marker id="a1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
          <path d="M0,0 L10,5 L0,10 z" fill="#c084fc"/></marker>
        <marker id="a2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
          <path d="M0,0 L10,5 L0,10 z" fill="#60a5fa"/></marker>
        <marker id="a0" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
          <path d="M0,0 L10,5 L0,10 z" fill="#8b93a7"/></marker>
      </defs>
      <rect x="12" y="44" width="568" height="180" rx="14" fill="#0f1629" stroke="#34d399" stroke-dasharray="6 4"/>
      <text x="28" y="214" fill="#34d399" font-size="12" font-weight="600">Pod demo-app · ServiceAccount demo-app</text>

      <g class="{{ '' if agent_enabled else 'off' }}">
        <rect x="32" y="64" width="170" height="58" rx="10" fill="#1d1533" stroke="#c084fc"/>
        <text x="117" y="88" fill="#c084fc" font-size="13" font-weight="700" text-anchor="middle">openbao-agent</text>
        <text x="117" y="106" fill="#8b93a7" font-size="11" text-anchor="middle">sidecar · renews token</text>
        <rect x="246" y="64" width="170" height="58" rx="10" fill="#141c33" stroke="#c084fc" stroke-dasharray="4 3"/>
        <text x="331" y="88" fill="#e6e9f2" font-size="12" text-anchor="middle" class="mt">/vault/secrets/config</text>
        <text x="331" y="106" fill="#8b93a7" font-size="11" text-anchor="middle">shared emptyDir · JSON</text>
        <line x1="202" y1="93" x2="244" y2="93" stroke="#c084fc" stroke-width="2" marker-end="url(#a1)"/>
        <line x1="331" y1="122" x2="331" y2="146" stroke="#c084fc" stroke-width="2" marker-end="url(#a1)"/>
        <text x="338" y="139" fill="#c084fc" font-size="11">read file</text>
        <path d="M117,64 V24 H700 V54" fill="none" stroke="#c084fc" stroke-width="2" marker-end="url(#a1)"/>
        <circle cx="300" cy="24" r="10" fill="#c084fc"/><text x="300" y="28" class="n">1</text>
        <text x="318" y="18" fill="#c084fc" font-size="11">login + read · re-render every {{ render_interval }} s</text>
      </g>

      <rect x="246" y="148" width="170" height="52" rx="10" fill="#2a1d0a" stroke="#ffb020"/>
      <text x="331" y="171" fill="#ffb020" font-size="13" font-weight="700" text-anchor="middle">App (Flask)</text>
      <text x="331" y="188" fill="#8b93a7" font-size="11" text-anchor="middle">this page</text>

      <g class="{{ '' if api_enabled else 'off' }}">
        <path d="M416,174 H620 V92 H638" fill="none" stroke="#60a5fa" stroke-width="2" marker-end="url(#a2)"/>
        <circle cx="510" cy="174" r="10" fill="#60a5fa"/><text x="510" y="178" class="n">2</text>
        <text x="430" y="198" fill="#60a5fa" font-size="11">login + KV v2 read / write</text>
      </g>

      <rect x="640" y="56" width="248" height="72" rx="12" fill="#1f1a08" stroke="#fbbf24"/>
      <text x="764" y="82" fill="#fbbf24" font-size="14" font-weight="700" text-anchor="middle">OpenBao</text>
      <text x="764" y="100" fill="#8b93a7" font-size="11" text-anchor="middle">auth/kubernetes · role {{ role }}</text>
      <text x="764" y="116" fill="#8b93a7" font-size="11" text-anchor="middle" class="mt">kv/{{ path }}</text>
      <rect x="640" y="164" width="248" height="52" rx="12" fill="#121a2f" stroke="#8b93a7"/>
      <text x="764" y="187" fill="#e6e9f2" font-size="13" font-weight="600" text-anchor="middle">Kubernetes API</text>
      <text x="764" y="204" fill="#8b93a7" font-size="11" text-anchor="middle">TokenReview validates the SA JWT</text>
      <line x1="764" y1="128" x2="764" y2="162" stroke="#8b93a7" stroke-width="1.5" stroke-dasharray="4 3" marker-end="url(#a0)"/>
    </svg>
  </section>

  <div class="two">
    <section class="card way1 {{ '' if agent_enabled else 'off' }}">
      <h2><span class="num w1">1</span>Agent sidecar → file</h2>
      <p class="hint">The injector adds an <code>openbao-agent</code> sidecar. It logs in, renders the secret into a file
        and refreshes it every {{ render_interval }} s. The app just reads a file — no OpenBao client, no tokens.</p>
      {% if agent_enabled %}
      <dl class="facts">
        <dt>File</dt><dd class="mono">{{ secret_file }}</dd>
        <dt>File changed</dt><dd>{{ ('%d s ago' % file_age) if file_age is not none else 'not yet' }}</dd>
        <dt>Read time</dt><dd>{{ file_ms }} ms (local file)</dd>
      </dl>
      <ul class="pros">
        <li><b>+</b> zero code dependency, works for any language or config file</li>
        <li><b>+</b> last rendered file survives a short OpenBao outage</li>
        <li><b>−</b> read-only, changes arrive with up to {{ render_interval }} s delay</li>
      </ul>
      <pre>{% raw %}vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "{% endraw %}{{ role }}{% raw %}"
vault.hashicorp.com/agent-inject-secret-config: "kv/data/{% endraw %}{{ path }}{% raw %}"
vault.hashicorp.com/agent-inject-template-config: |
  {{- with secret "kv/data/…" -}}{{ .Data.data | toJSON }}{{- end -}}{% endraw %}</pre>
      <table>
        <tr><th>Key</th><th>Value from file</th></tr>
        {% for k, v in (injected or {}).items() %}
        <tr><td class="mono key">{{ k }}</td><td class="mono val">{{ v }}</td></tr>
        {% else %}
        <tr><td colspan="2" class="missing">{{ 'File not rendered yet.' if injected is none else 'Secret is empty.' }}</td></tr>
        {% endfor %}
      </table>
      {% else %}
      <p class="disabled-note">Disabled in mode <code>{{ access_mode }}</code> (no injector annotations).</p>
      {% endif %}
    </section>

    <section class="card way2 {{ '' if api_enabled else 'off' }}">
      <h2><span class="num w2">2</span>Direct API (Kubernetes auth)</h2>
      <p class="hint">The app logs in itself with its ServiceAccount JWT, caches the client token and calls the
        KV v2 API — immediate reads plus writes, versions and check-and-set.</p>
      {% if api_enabled %}
      <dl class="facts">
        <dt>Endpoint</dt><dd class="mono">{{ bao_addr }}</dd>
        <dt>Version</dt><dd>{{ ('v%s' % meta.version) if meta.version else '—' }}</dd>
        <dt>Token</dt><dd>{{ ('cached, %d s of %d s left' % (token.remaining, token.ttl)) if token else '—' }}</dd>
        <dt>Read time</dt><dd>{{ api_ms if api_ms is not none else '—' }} ms (network + OpenBao)</dd>
      </dl>
      <ul class="pros">
        <li><b>+</b> always current, can write, list versions and restore</li>
        <li><b>−</b> needs OpenBao client code and token handling in the app</li>
        <li><b>−</b> every read depends on OpenBao being reachable</li>
      </ul>
      <pre>POST {{ bao_addr }}/v1/auth/kubernetes/login
     {"role": "{{ role }}", "jwt": "&lt;ServiceAccount token&gt;"}
GET  /v1/kv/data/{{ path }}        X-Vault-Token: …
POST /v1/kv/data/{{ path }}        {"options": {"cas": N}, "data": {…}}</pre>
      <table>
        <tr><th>Key</th><th>Value from API</th></tr>
        {% for k, v in live.items() %}
        <tr><td class="mono key">{{ k }}</td><td class="mono val">{{ v }}</td></tr>
        {% else %}
        <tr><td colspan="2" class="missing">{{ 'API not reachable.' if error else 'Secret is empty.' }}</td></tr>
        {% endfor %}
      </table>
      {% else %}
      <p class="disabled-note">Disabled in mode <code>{{ access_mode }}</code>.</p>
      {% endif %}
    </section>
  </div>

  {% if compare %}
  <section class="card section-gap">
    <h2>Compare ① file vs ② API</h2>
    <p class="hint">After a write the API answers immediately; the file follows with the next sidecar render.</p>
    <table>
      <tr><th>Key</th><th>① File</th><th>② API</th><th></th></tr>
      {% for key in keys %}
      {% set l, i = live.get(key), injected.get(key) %}
      <tr>
        <td class="mono key">{{ key }}</td>
        <td class="mono {{ 'val' if i is not none else 'missing' }}">{{ i if i is not none else 'not yet' }}</td>
        <td class="mono {{ 'val' if l is not none else 'missing' }}">{{ l if l is not none else 'removed' }}</td>
        <td><span class="state"><span class="dot {{ 'ok' if l == i else 'warn' }}"></span>
          {{- 'synced' if l == i else 'pending' }}</span></td>
      </tr>
      {% else %}
      <tr><td colspan="4" class="missing">No secret data yet.</td></tr>
      {% endfor %}
    </table>
  </section>
  {% endif %}

  {% if api_enabled and not error %}
  <div class="grid section-gap">
    <section class="card">
      <h2>Edit secret <span class="badge">via ②</span></h2>
      <p class="hint">Saving creates a new version with check-and-set (<code>cas={{ meta.version or 0 }}</code>) —
        concurrent edits are rejected instead of overwritten.{% if agent_enabled %} Then watch ① catch up.{% endif %}</p>
      <form method="POST" action="{{ url_for('update_secrets') }}">
        <input type="hidden" name="csrf" value="{{ csrf }}">
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

    <section class="card">
      <h2>Version history <span class="badge">via ②</span></h2>
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
              <input type="hidden" name="csrf" value="{{ csrf }}">
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
  </div>
  {% endif %}

  <footer>Build {{ version }}</footer>
</div>
{% if saved and compare and not in_sync and since_save is not none and since_save < render_interval + 60 %}
<script>
  // Poll until the sidecar has re-rendered the file after the last write.
  let s = {{ since_save }};
  setInterval(() => { s += 1; const e = document.getElementById("elapsed"); if (e) e.textContent = s; }, 1000);
  setTimeout(() => location.reload(), 3000);
</script>
{% endif %}
</body>
</html>
"""


@app.route("/")
def index():
    injected, mtime, file_ms = None, None, None
    if AGENT_ENABLED:
        (injected, mtime), file_ms = timed(read_injected)
    live, meta, history, current, error, api_ms = {}, {}, [], 0, None, None
    if API_ENABLED:
        try:
            (live, meta), api_ms = timed(read_secret)
            history, current = read_history()
        except (BaoError, OSError, requests.RequestException) as e:
            error = f"OpenBao API not reachable: {e}"
    compare = AGENT_ENABLED and API_ENABLED and not error and injected is not None
    keys = sorted(set(live) | set(injected or {}))
    in_sync = compare and injected == live
    saved_at = request.args.get("at", type=int)
    rendered_after_save = bool(saved_at and mtime and mtime >= saved_at)
    return render_template_string(
        TEMPLATE, path=SECRET_PATH, secret_file=SECRET_FILE, role=BAO_ROLE, bao_addr=BAO_ADDR,
        render_interval=RENDER_INTERVAL, agent_enabled=AGENT_ENABLED, api_enabled=API_ENABLED,
        live=live, injected=injected, keys=keys, meta=meta, history=history, current=current,
        error=error, compare=compare, in_sync=in_sync, version=VERSION, access_mode=ACCESS_MODE,
        file_age=int(time.time() - mtime) if mtime else None, file_ms=file_ms, api_ms=api_ms,
        token=token_info(), saved=request.args.get("saved"), saved_at=saved_at,
        since_save=int(time.time() - saved_at) if saved_at else None, rendered_after_save=rendered_after_save,
        sync_latency=max(0, int(mtime - saved_at)) if rendered_after_save else None,
        csrf=csrf_token(), flash_msg=request.args.get("msg"), flash_type=request.args.get("type", "ok"))


@app.route("/secrets", methods=["POST"])
def update_secrets():
    if not API_ENABLED:
        return back("Agent-only mode is read-only; select api or both to edit secrets.", "err")
    form = request.form
    deleted = set(form.getlist("delete"))
    data = {k: v.strip() for k, v in zip(form.getlist("key"), form.getlist("value")) if k not in deleted}
    new_key, new_value = form.get("new_key", "").strip(), form.get("new_value", "").strip()
    if new_key:
        if not KEY_PATTERN.match(new_key):
            return back("Invalid key: use 1-64 characters A-Z a-z 0-9 _ . -", "err")
        data[new_key] = new_value
    try:
        version = write_secret(data, int(form.get("cas", 0)))
    except (BaoError, OSError, ValueError, requests.RequestException) as e:
        return back(f"Save failed: {e}", "err")
    return back(f"Saved version {version} via the API", saved=version)


@app.route("/restore/<int:version>", methods=["POST"])
def restore(version):
    if not API_ENABLED:
        return back("Agent-only mode is read-only; select api or both to restore versions.", "err")
    try:
        data, _ = read_secret(version)
        new_version = write_secret(data, int(request.form.get("cas", 0)))
    except (BaoError, OSError, ValueError, requests.RequestException) as e:
        return back(f"Restore failed: {e}", "err")
    return back(f"Restored v{version} as version {new_version}", saved=new_version)


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
