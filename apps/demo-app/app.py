from flask import Flask, render_template_string, request, redirect, url_for
import os, requests

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "dev")
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault.vault.svc:8200")
SECRET_FILE = os.environ.get("VAULT_SECRET_FILE", "/vault/secrets/config")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"


def get_vault_token():
    """Login to Vault via Kubernetes auth."""
    try:
        with open(SA_TOKEN_PATH) as f:
            jwt = f.read()
        r = requests.post(f"{VAULT_ADDR}/v1/auth/kubernetes/login",
                          json={"role": "demo-app", "jwt": jwt})
        r.raise_for_status()
        return r.json()["auth"]["client_token"]
    except Exception:
        return None


def read_secrets():
    """Read secrets from Vault Agent injected file."""
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


def write_secrets(token, data):
    """Write secrets to Vault via API."""
    r = requests.post(f"{VAULT_ADDR}/v1/kv/data/demo/config",
                      headers={"X-Vault-Token": token},
                      json={"data": data})
    r.raise_for_status()


TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
  <title>Vault Demo</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, sans-serif; background: #1a1a2e; color: #e0e0e0;
           display: flex; justify-content: center; align-items: center; min-height: 100vh; }
    .card { background: #16213e; border-radius: 12px; padding: 40px; max-width: 560px;
            width: 90%; box-shadow: 0 8px 32px rgba(0,0,0,.3); }
    h1 { color: #f1c40f; margin-bottom: 8px; font-size: 24px; }
    .sub { color: #889; margin-bottom: 24px; font-size: 14px; }
    .secret-box { background: #1a1a2e; border: 1px solid #2d3a5a; border-radius: 8px;
                  padding: 16px; margin-bottom: 12px; }
    .label { color: #4a6fa5; font-size: 11px; text-transform: uppercase;
             letter-spacing: 1px; margin-bottom: 6px; }
    .value { color: #2ecc71; font-family: monospace; font-size: 16px; word-break: break-all; }
    .value.missing { color: #e74c3c; }
    .source { color: #556; font-size: 10px; margin-top: 4px; }
    .footer { color: #556; font-size: 11px; margin-top: 20px; text-align: center; }
    .status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
    .status.ok { background: #2ecc71; }
    .status.err { background: #e74c3c; }
    hr { border: none; border-top: 1px solid #2d3a5a; margin: 24px 0; }
    h2 { color: #e0e0e0; font-size: 16px; margin-bottom: 16px; }
    form { display: flex; flex-direction: column; gap: 12px; }
    .field { display: flex; flex-direction: column; gap: 4px; }
    .field label { color: #4a6fa5; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; }
    .field input { background: #1a1a2e; border: 1px solid #2d3a5a; border-radius: 6px;
                   color: #e0e0e0; padding: 10px 12px; font-size: 14px; font-family: monospace; }
    .field input:focus { outline: none; border-color: #f1c40f; }
    button { background: #f1c40f; color: #1a1a2e; border: none; border-radius: 6px;
             padding: 10px 20px; font-size: 14px; font-weight: 600; cursor: pointer;
             align-self: flex-start; }
    button:hover { background: #f39c12; }
    .msg { padding: 10px 14px; border-radius: 6px; font-size: 13px; margin-bottom: 16px; }
    .msg.ok { background: rgba(46,204,113,.15); color: #2ecc71; }
    .msg.err { background: rgba(231,76,60,.15); color: #e74c3c; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Vault Demo</h1>
    <p class="sub">Read: Vault Agent Sidecar · Write: Vault API</p>

    {% if flash_msg %}
    <div class="msg {{ flash_type }}">{{ flash_msg }}</div>
    {% endif %}

    <div class="secret-box">
      <div class="label">demo/message</div>
      <div class="value {{ 'missing' if not secrets.get('message') }}">{{ secrets.get('message') or 'not found' }}</div>
    </div>

    <div class="secret-box">
      <div class="label">demo/api_key</div>
      <div class="value {{ 'missing' if not secrets.get('api_key') }}">{{ secrets.get('api_key') or 'not found' }}</div>
    </div>

    <div class="footer">
      <span class="status {{ 'ok' if secrets.get('message') else 'err' }}"></span>
      {{ 'Secrets loaded via Injector' if secrets.get('message') else 'Waiting for Vault Agent…' }} · {{ version }}
    </div>

    <hr>
    <h2>Update Secrets</h2>
    <form method="POST" action="/secrets">
      <div class="field">
        <label>message</label>
        <input type="text" name="message" value="{{ secrets.get('message', '') }}" placeholder="Hello from Vault">
      </div>
      <div class="field">
        <label>api_key</label>
        <input type="text" name="api_key" value="{{ secrets.get('api_key', '') }}" placeholder="sk-demo-1234567890">
      </div>
      <button type="submit">Save to Vault</button>
    </form>
  </div>
</body>
</html>
"""


@app.route("/")
def index():
    secrets = read_secrets()
    flash_msg = request.args.get("msg")
    flash_type = request.args.get("type", "ok")
    return render_template_string(TEMPLATE,
                                 secrets=secrets,
                                 version=VERSION,
                                 flash_msg=flash_msg,
                                 flash_type=flash_type)


@app.route("/secrets", methods=["POST"])
def update_secrets():
    token = get_vault_token()
    if not token:
        return redirect(url_for("index", msg="Vault login failed", type="err"))

    data = {
        "message": request.form.get("message", ""),
        "api_key": request.form.get("api_key", ""),
    }
    try:
        write_secrets(token, data)
        return redirect(url_for("index", msg="Secrets saved (reload after ~30s for Injector update)"))
    except Exception as e:
        return redirect(url_for("index", msg=f"Save failed: {e}", type="err"))


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
