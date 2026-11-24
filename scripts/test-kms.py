#!/usr/bin/env python3
"""
Test the KMS encrypt/decrypt round-trip used by the OpenBao auto-unseal.
Uses TF_VAR_otc_access_key / TF_VAR_otc_secret_key for API signing.
Usage: ./scripts/test-kms.py [kms-key-id]
"""
import base64
import json
import os
import subprocess
import sys
from urllib.request import Request, urlopen

REGION = os.environ.get("OTC_REGION", "eu-de")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INFRA_DIR = os.path.join(SCRIPT_DIR, "..", "infra")

# --- Credentials ---
AK = os.environ.get("TF_VAR_otc_access_key") or sys.exit("Set TF_VAR_otc_access_key")
SK = os.environ.get("TF_VAR_otc_secret_key") or sys.exit("Set TF_VAR_otc_secret_key")
DOMAIN = os.environ.get("TF_VAR_otc_domain_name") or sys.exit("Set TF_VAR_otc_domain_name")

# Project name from TF_VAR_otc_project_name
PROJECT_NAME = os.environ.get("TF_VAR_otc_project_name") or sys.exit("Set TF_VAR_otc_project_name")


def get_token_and_project_id():
    """Get IAM token and project ID using AK/SK via hw_ak_sk identity method."""
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
            "scope": {
                "project": {"name": PROJECT_NAME}
            }
        }
    })
    req = Request(url, data=body.encode(), method="POST",
                  headers={"Content-Type": "application/json"})
    resp = urlopen(req)
    token = resp.headers.get("X-Subject-Token")
    data = json.loads(resp.read())
    project_id = data["token"]["project"]["id"]
    return token, project_id


def api_call(method, url, token, body=""):
    """Make a token-authenticated API call."""
    headers = {"X-Auth-Token": token, "Content-Type": "application/json"}
    data = body.encode() if method == "POST" and body else None
    req = Request(url, data=data, headers=headers, method=method)
    return json.loads(urlopen(req).read())


def kms_encrypt(project_id, token, key_id, plaintext_b64):
    url = f"https://kms.{REGION}.otc.t-systems.com/v1.0/{project_id}/kms/encrypt-data"
    body = json.dumps({"key_id": key_id, "plain_text": plaintext_b64})
    return api_call("POST", url, token, body)


def kms_decrypt(project_id, token, cipher_text):
    url = f"https://kms.{REGION}.otc.t-systems.com/v1.0/{project_id}/kms/decrypt-data"
    body = json.dumps({"cipher_text": cipher_text})
    return api_call("POST", url, token, body)


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


def main():
    if len(sys.argv) >= 2:
        kms_key_id = sys.argv[1]
    else:
        print("=== Reading from tofu output ===")
        kms_key_id = get_tf_output("openbao_unseal_kms_key_id")
        if not kms_key_id:
            sys.exit("Could not read infra output openbao_unseal_kms_key_id. Pass <kms-key-id> as argument.")

    print(f"KMS Key:    {kms_key_id}")
    print(f"Project:    {PROJECT_NAME}")

    print("\n=== Getting token + project ID ===")
    token, project_id = get_token_and_project_id()
    print(f"Project ID: {project_id}")

    test_data = "unseal-key-1:abc123,unseal-key-2:def456,unseal-key-3:ghi789"

    print("\n=== 1. KMS Encrypt ===")
    plaintext_b64 = base64.b64encode(test_data.encode()).decode()
    enc_resp = kms_encrypt(project_id, token, kms_key_id, plaintext_b64)
    cipher_text = enc_resp.get("cipher_text", "")
    if not cipher_text:
        sys.exit(f"Encryption failed: {enc_resp}")
    print(f"Cipher text: {cipher_text[:50]}...")

    print("\n=== 2. KMS Decrypt ===")
    dec_resp = kms_decrypt(project_id, token, cipher_text)
    decrypted_b64 = dec_resp.get("plain_text", "")
    if not decrypted_b64:
        sys.exit(f"Decryption failed: {sorted(dec_resp)}")
    decrypted = base64.b64decode(decrypted_b64).decode()

    print()
    if decrypted == test_data:
        print("SUCCESS: KMS round-trip works (same format as the auto-unseal sidecar)")
    else:
        print("FAIL: mismatch")
        sys.exit(1)


if __name__ == "__main__":
    main()
