#!/usr/bin/env python3
"""
Upload OpenBao unseal keys to OBS (KMS encrypted).
Reads keys from an openbao.keys.* file (written by openbao-init.sh) or stdin.

Usage:
  ./scripts/upload-unseal-keys.py <openbao-keys-file>
  ./scripts/upload-unseal-keys.py  (reads from stdin)
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

REGION = "eu-de"
OBS_ENDPOINT = f"https://obs.{REGION}.otc.t-systems.com"
OBJECT_KEY = "openbao-unseal/keys.enc"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INFRA_DIR = os.path.join(SCRIPT_DIR, "..", "infra")

AK = os.environ.get("TF_VAR_otc_access_key") or sys.exit("Set TF_VAR_otc_access_key")
SK = os.environ.get("TF_VAR_otc_secret_key") or sys.exit("Set TF_VAR_otc_secret_key")
DOMAIN = os.environ.get("TF_VAR_otc_domain_name") or sys.exit("Set TF_VAR_otc_domain_name")

PROJECT_NAME = os.environ.get("TF_VAR_otc_project_name") or sys.exit("Set TF_VAR_otc_project_name")


def get_token_and_project_id():
    url = f"https://iam.{REGION}.otc.t-systems.com/v3/auth/tokens"
    body = json.dumps({
        "auth": {
            "identity": {
                "methods": ["hw_ak_sk"],
                "hw_ak_sk": {
                    "access": {"key": AK},
                    "secret": {"key": SK}
                }
            },
            "scope": {"project": {"name": PROJECT_NAME}}
        }
    })
    req = Request(url, data=body.encode(), method="POST",
                  headers={"Content-Type": "application/json"})
    resp = urlopen(req)
    token = resp.headers.get("X-Subject-Token")
    data = json.loads(resp.read())
    project_id = data["token"]["project"]["id"]
    return token, project_id


def get_tf_output(name):
    for cmd in ["tofu", "terraform"]:
        try:
            result = subprocess.run(
                [cmd, "output", "-raw", name],
                capture_output=True, text=True, cwd=INFRA_DIR,
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except FileNotFoundError:
            continue
    return None


def parse_unseal_keys(content):
    """Extract unseal keys from an openbao.keys.* file."""
    keys = []
    for line in content.strip().splitlines():
        m = re.match(r'Unseal Key \d+:\s*(.+)', line)
        if m:
            keys.append(m.group(1).strip())
    if not keys:
        sys.exit("No unseal keys found. Expected lines like: 'Unseal Key 1: ...'")
    return keys


def main():
    # Read unseal keys
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            content = f.read()
    else:
        print("Paste openbao.keys content (Ctrl+D when done):")
        content = sys.stdin.read()

    unseal_keys = parse_unseal_keys(content)
    print(f"Found {len(unseal_keys)} unseal keys")

    # Get KMS key ID and bucket
    kms_key_id = get_tf_output("openbao_unseal_kms_key_id")
    obs_bucket = get_tf_output("openbao_unseal_obs_bucket")
    if not kms_key_id or not obs_bucket:
        sys.exit("Could not read terraform outputs")

    print(f"KMS Key:    {kms_key_id}")
    print(f"OBS Bucket: {obs_bucket}")

    # Get token
    print("\n=== Authenticating ===")
    token, project_id = get_token_and_project_id()
    print(f"Project ID: {project_id}")

    # KMS encrypt
    print("\n=== Encrypting unseal keys ===")
    plaintext = ",".join(unseal_keys)
    plaintext_b64 = base64.b64encode(plaintext.encode()).decode()

    kms_body = json.dumps({"key_id": kms_key_id, "plain_text": plaintext_b64})
    kms_req = Request(
        f"https://kms.{REGION}.otc.t-systems.com/v1.0/{project_id}/kms/encrypt-data",
        data=kms_body.encode(), method="POST",
        headers={"X-Auth-Token": token, "Content-Type": "application/json"},
    )
    kms_resp = json.loads(urlopen(kms_req).read())
    cipher_text = kms_resp.get("cipher_text", "")
    if not cipher_text:
        sys.exit(f"Encryption failed: {kms_resp}")
    print(f"Encrypted: {len(cipher_text)} chars")

    # Upload to OBS
    print("\n=== Uploading to OBS ===")
    env = {
        **os.environ,
        "AWS_ACCESS_KEY_ID": AK,
        "AWS_SECRET_ACCESS_KEY": SK,
        "AWS_REQUEST_CHECKSUM_CALCULATION": "WHEN_REQUIRED",
        "AWS_RESPONSE_CHECKSUM_VALIDATION": "WHEN_REQUIRED",
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".enc", delete=False) as f:
        f.write(cipher_text)
        tmp = f.name
    try:
        subprocess.run(
            ["aws", "s3", "cp", tmp, f"s3://{obs_bucket}/{OBJECT_KEY}",
             "--endpoint-url", OBS_ENDPOINT, "--quiet"],
            env=env, check=True,
        )
    finally:
        os.unlink(tmp)

    print(f"Stored: s3://{obs_bucket}/{OBJECT_KEY}")
    print(f"\nSUCCESS: {len(unseal_keys)} unseal keys encrypted and uploaded")
    print("\nTo test the FunctionGraph function, invoke with:")
    print(f'  {{"bucket": "{obs_bucket}", "object_key": "{OBJECT_KEY}", "kms_key_id": "{kms_key_id}"}}')


if __name__ == "__main__":
    main()
