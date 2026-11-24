"""Native sidecar of each OpenBao server pod: unseal the local server whenever it
reports initialized + sealed.

The KMS ciphertext comes from the Secret openbao-unseal-keys (mounted at
/unseal-keys). It is decrypted with an IAM token obtained via workload identity
(projected ServiceAccount token), and the shares are sent to 127.0.0.1 only.
Shares and tokens stay in this process: no files, no argv, no logs.

Deleting the Secret pauses the sidecar (checked before every share); see
scripts/openbao-seal.sh for a deliberate seal.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

BAO = "http://127.0.0.1:8200"
CIPHER_FILE = "/unseal-keys/keys.enc"
OIDC_TOKEN_FILE = "/var/run/secrets/tokens/oidc-token"
INTERVAL = int(os.environ.get("UNSEAL_INTERVAL", "30"))
REGION = os.environ["REGION"]
IDP_ID = os.environ["IDP_ID"]
PROJECT_NAME = os.environ["PROJECT_NAME"]


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg, flush=True)


# Local OpenBao traffic never goes through a proxy, whatever HTTP(S)_PROXY / NO_PROXY say;
# IAM/KMS calls keep the environment's proxy settings.
LOCAL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
DEFAULT_OPENER = urllib.request.build_opener()


def request(url, body=None, method=None, headers=None, timeout=10):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"),
                                 headers={"Content-Type": "application/json", **(headers or {})})
    opener = LOCAL_OPENER if url.startswith(BAO + "/") else DEFAULT_OPENER
    with opener.open(req, timeout=timeout) as resp:  # noqa: S310 - fixed endpoints
        return resp.headers, json.loads(resp.read() or b"{}")


def seal_status():
    try:
        return request(f"{BAO}/v1/sys/seal-status", timeout=5)[1]
    except (OSError, ValueError):
        return None  # server not listening yet


def keys_present():
    return os.path.isfile(CIPHER_FILE) and os.path.getsize(CIPHER_FILE) > 0


def iam_token():
    """Workload identity: projected SA token -> IAM token + project ID."""
    with open(OIDC_TOKEN_FILE) as f:
        oidc = f.read().strip()
    body = {"auth": {"id_token": {"id": oidc}, "scope": {"project": {"name": PROJECT_NAME}}}}
    headers, data = request(f"https://iam.{REGION}.otc.t-systems.com/v3.0/OS-AUTH/id-token/tokens",
                            body, headers={"X-Idp-Id": IDP_ID})
    token = headers.get("X-Subject-Token")
    project_id = data.get("token", {}).get("project", {}).get("id")
    if not token or not project_id:
        raise ValueError("IAM response without token or project")
    return token, project_id


def decrypt_shares(token, project_id):
    """KMS decrypt-data; plain_text = base64("share1,share2,...") from upload-unseal-keys.py."""
    with open(CIPHER_FILE) as f:
        cipher = f.read().strip()
    _, data = request(f"https://kms.{REGION}.otc.t-systems.com/v1.0/{project_id}/kms/decrypt-data",
                      {"cipher_text": cipher}, headers={"X-Auth-Token": token})
    shares = [s.strip() for s in base64.b64decode(data["plain_text"], validate=True).decode().split(",") if s.strip()]
    if not shares:
        raise ValueError("no shares in KMS plaintext")
    return shares


def unseal():
    try:
        token, project_id = iam_token()
    except (OSError, ValueError, KeyError) as e:
        log(f"IAM token exchange failed ({type(e).__name__}: {getattr(e, 'code', '')})")
        return
    try:
        shares = decrypt_shares(token, project_id)
    except (OSError, ValueError, KeyError) as e:
        log(f"KMS decrypt failed ({type(e).__name__}: {getattr(e, 'code', '')})")
        return
    finally:
        token = None
    try:
        for share in shares:
            if not keys_present():
                log("paused: Secret openbao-unseal-keys removed during unseal")
                return
            _, result = request(f"{BAO}/v1/sys/unseal", {"key": share}, method="PUT", timeout=5)
            if result.get("sealed") is False:
                log("unsealed")
                return
        log("all shares submitted, server still sealed")
    except (OSError, ValueError) as e:
        log(f"unseal request failed ({type(e).__name__}: {getattr(e, 'code', '')})")
    finally:
        shares = None


def main():
    log(f"auto-unseal sidecar started (check every {INTERVAL}s)")
    paused = False
    while True:
        status = seal_status()
        if status is None:
            time.sleep(3)
            continue
        if not keys_present():
            if not paused:
                log("paused: Secret openbao-unseal-keys missing (unseal manually or run scripts/upload-unseal-keys.py)")
            paused = True
        else:
            if paused:
                log("resumed: Secret openbao-unseal-keys present")
            paused = False
            if status.get("initialized") is True and status.get("sealed") is True:
                unseal()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
