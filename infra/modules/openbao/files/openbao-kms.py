#!/usr/bin/env python3
"""OTC KMS encrypt/decrypt using AKSK signing with temporary agency credentials."""
import sys
import json
import hashlib
import hmac
import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError

def sign(sk, msg):
    return hmac.new(sk, msg.encode(), hashlib.sha256).digest()

def get_signature_key(sk, date, region, service):
    k = sign(("SDK" + sk).encode(), date)
    k = sign(k, region)
    k = sign(k, service)
    return sign(k, "sdk_request")

def aksk_request(method, url, body, ak, sk, security_token, region):
    """Make an AKSK-signed request to an OTC API."""
    from urllib.parse import urlparse
    parsed = urlparse(url)
    host = parsed.hostname
    path = parsed.path or "/"
    if not path.endswith("/"):
        path += "/"

    now = datetime.datetime.utcnow()
    timestamp = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    body_bytes = body.encode() if isinstance(body, str) else body
    payload_hash = hashlib.sha256(body_bytes).hexdigest()

    headers = {
        "Host": host,
        "X-Sdk-Date": timestamp,
        "Content-Type": "application/json",
    }
    if security_token:
        headers["X-Security-Token"] = security_token

    signed_header_keys = sorted(k.lower() for k in headers)
    signed_headers_str = ";".join(signed_header_keys)
    canonical_headers = "".join(f"{k.lower()}:{headers[k]}\n" for k in sorted(headers, key=str.lower))

    canonical_request = f"{method}\n{path}\n\n{canonical_headers}\n{signed_headers_str}\n{payload_hash}"
    credential_scope = f"{datestamp}/{region}/kms/sdk_request"
    string_to_sign = f"SDK-HMAC-SHA256\n{timestamp}\n{credential_scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}"

    signing_key = get_signature_key(sk, datestamp, region, "kms")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    headers["Authorization"] = (
        f"SDK-HMAC-SHA256 Credential={ak}/{credential_scope}, "
        f"SignedHeaders={signed_headers_str}, Signature={signature}"
    )

    req = Request(url, data=body_bytes, headers=headers, method=method)
    try:
        resp = urlopen(req)
        return json.loads(resp.read())
    except HTTPError as e:
        err = e.read().decode()
        print(f"ERROR: KMS API {e.code}: {err}", file=sys.stderr)
        sys.exit(1)

def get_creds():
    """Get temporary credentials from ECS metadata service."""
    from urllib.request import urlopen as uo
    creds = json.loads(uo("http://169.254.169.254/openstack/latest/securitykey").read())["credential"]
    meta = json.loads(uo("http://169.254.169.254/openstack/latest/meta_data.json").read())
    return creds["access"], creds["secret"], creds.get("securitytoken", ""), meta["project_id"]

def main():
    if len(sys.argv) < 3:
        print("Usage: openbao-kms.py <encrypt|decrypt> <key_id> [plain_text|cipher_text]", file=sys.stderr)
        print("  Reads from stdin if third argument is omitted.", file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]
    key_id = sys.argv[2]
    data = sys.argv[3] if len(sys.argv) > 3 else sys.stdin.read().strip()

    with open("/etc/openbao/auto-unseal.env") as f:
        env = dict(line.strip().split("=", 1) for line in f if "=" in line and not line.startswith("#"))
    region = env.get("KMS_REGION", "eu-de")

    ak, sk, st, project_id = get_creds()

    if action == "encrypt":
        url = f"https://kms.{region}.otc.t-systems.com/v1.0/{project_id}/kms/encrypt-data"
        body = json.dumps({"key_id": key_id, "plain_text": data})
        result = aksk_request("POST", url, body, ak, sk, st, region)
        print(result.get("cipher_text", ""))
    elif action == "decrypt":
        url = f"https://kms.{region}.otc.t-systems.com/v1.0/{project_id}/kms/decrypt-data"
        body = json.dumps({"cipher_text": data})
        result = aksk_request("POST", url, body, ak, sk, st, region)
        print(result.get("plain_text", ""))
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
