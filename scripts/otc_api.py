"""
Minimal signed OTC API client (SDK-HMAC-SHA256), stdlib only.

Credentials: TF_VAR_otc_access_key, TF_VAR_otc_secret_key, TF_VAR_otc_project_name.
Region: OTC_REGION (default eu-de).
"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

REGION = os.environ.get("OTC_REGION", "eu-de")

AK = os.environ.get("TF_VAR_otc_access_key") or sys.exit("Set TF_VAR_otc_access_key")
SK = os.environ.get("TF_VAR_otc_secret_key") or sys.exit("Set TF_VAR_otc_secret_key")
PROJECT_NAME = os.environ.get("TF_VAR_otc_project_name") or sys.exit("Set TF_VAR_otc_project_name")


def host(service):
    return f"{service}.{REGION}.otc.t-systems.com"


def call(method, host, path, query=None, headers=None, body=None):
    """Signed OTC API request. `body` is JSON-encoded. Returns (status, parsed body)."""
    q = urllib.parse.urlencode(sorted((query or {}).items()))
    payload = json.dumps(body).encode() if body is not None else b""
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    h = {"host": host, "x-sdk-date": stamp, "content-type": "application/json", **(headers or {})}
    signed = ";".join(sorted(h))
    canonical = (
        f"{method}\n{path}{'' if path.endswith('/') else '/'}\n{q}\n"
        + "".join(f"{k}:{h[k]}\n" for k in sorted(h))
        + f"\n{signed}\n{hashlib.sha256(payload).hexdigest()}"
    )
    to_sign = f"SDK-HMAC-SHA256\n{stamp}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
    signature = hmac.new(SK.encode(), to_sign.encode(), hashlib.sha256).hexdigest()
    auth = f"SDK-HMAC-SHA256 Access={AK}, SignedHeaders={signed}, Signature={signature}"
    url = f"https://{host}{path}" + (f"?{q}" if q else "")
    req = urllib.request.Request(url, data=payload or None, method=method, headers={**h, "Authorization": auth})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            return resp.status, json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


def project_id():
    status, data = call("GET", host("iam"), "/v3/projects", {"name": PROJECT_NAME})
    if status != 200 or not data.get("projects"):
        sys.exit(f"Could not resolve project {PROJECT_NAME}: HTTP {status}")
    return data["projects"][0]["id"]
