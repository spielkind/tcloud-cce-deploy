#!/usr/bin/env python3
"""
Test KMS encrypt/decrypt + OBS storage round-trip.
Uses TF_VAR_otc_access_key / TF_VAR_otc_secret_key for API signing.
Usage: ./scripts/test-kms-obs.py [kms-key-id] [obs-bucket]
"""
import base64
import json
import os
import subprocess
import sys
from urllib.request import Request, urlopen

REGION = "eu-de"
OBS_ENDPOINT = f"https://obs.{REGION}.otc.t-systems.com"
OBJECT_KEY = "openbao-unseal/test-keys.enc"
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


def _obs_env():
    return {
        **os.environ,
        "AWS_ACCESS_KEY_ID": AK,
        "AWS_SECRET_ACCESS_KEY": SK,
        "AWS_REQUEST_CHECKSUM_CALCULATION": "WHEN_REQUIRED",
        "AWS_RESPONSE_CHECKSUM_VALIDATION": "WHEN_REQUIRED",
    }


def obs_put(bucket, key, data):
    """Upload data to OBS."""
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".enc", delete=False) as f:
        f.write(data)
        tmp = f.name
    try:
        subprocess.run(
            ["aws", "s3", "cp", tmp, f"s3://{bucket}/{key}",
             "--endpoint-url", OBS_ENDPOINT, "--quiet"],
            env=_obs_env(), check=True,
        )
    finally:
        os.unlink(tmp)


def obs_get(bucket, key):
    """Download data from OBS."""
    import tempfile
    with tempfile.NamedTemporaryFile(mode="r", suffix=".enc", delete=False) as f:
        tmp = f.name
    try:
        subprocess.run(
            ["aws", "s3", "cp", f"s3://{bucket}/{key}", tmp,
             "--endpoint-url", OBS_ENDPOINT, "--quiet"],
            env=_obs_env(), check=True,
        )
        with open(tmp) as f:
            return f.read().strip()
    finally:
        os.unlink(tmp)


def obs_delete(bucket, key):
    """Delete object from OBS."""
    subprocess.run(
        ["aws", "s3", "rm", f"s3://{bucket}/{key}",
         "--endpoint-url", OBS_ENDPOINT, "--quiet"],
        env=_obs_env(), check=True,
    )


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
    if len(sys.argv) >= 3:
        kms_key_id = sys.argv[1]
        obs_bucket = sys.argv[2]
    else:
        print("=== Reading from terraform output ===")
        kms_key_id = get_tf_output("openbao_unseal_kms_key_id")
        obs_bucket = get_tf_output("openbao_unseal_obs_bucket")
        if not kms_key_id or not obs_bucket:
            sys.exit("Could not read terraform outputs. Pass <kms-key-id> <obs-bucket> as args.")

    print(f"KMS Key:    {kms_key_id}")
    print(f"OBS Bucket: {obs_bucket}")
    print(f"Project:    {PROJECT_NAME}")

    print("\n=== Getting token + project ID ===")
    token, project_id = get_token_and_project_id()
    print(f"Project ID: {project_id}")
    print(f"Token: {token[:20]}...")

    test_data = "unseal-key-1:abc123,unseal-key-2:def456,unseal-key-3:ghi789"

    print("\n=== 1. KMS Encrypt ===")
    print(f"Plaintext: {test_data}")
    plaintext_b64 = base64.b64encode(test_data.encode()).decode()
    enc_resp = kms_encrypt(project_id, token, kms_key_id, plaintext_b64)
    cipher_text = enc_resp.get("cipher_text", "")
    if not cipher_text:
        sys.exit(f"Encryption failed: {enc_resp}")
    print(f"Cipher text: {cipher_text[:50]}...")

    print("\n=== 2. Upload to OBS ===")
    obs_put(obs_bucket, OBJECT_KEY, cipher_text)
    print(f"Stored: s3://{obs_bucket}/{OBJECT_KEY}")

    print("\n=== 3. Download from OBS ===")
    stored = obs_get(obs_bucket, OBJECT_KEY)
    print(f"Read back: {stored[:50]}...")

    print("\n=== 4. KMS Decrypt ===")
    dec_resp = kms_decrypt(project_id, token, stored)
    decrypted_b64 = dec_resp.get("plain_text", "")
    if not decrypted_b64:
        sys.exit(f"Decryption failed: {dec_resp}")
    decrypted = base64.b64decode(decrypted_b64).decode()
    print(f"Decrypted: {decrypted}")

    print()
    if decrypted == test_data:
        print("SUCCESS: Round-trip encrypt -> OBS -> decrypt works!")
    else:
        print("FAIL: mismatch")
        print(f"  Expected: {test_data}")
        print(f"  Got:      {decrypted}")
        sys.exit(1)

    print("\n=== 5. Cleanup ===")
    obs_delete(obs_bucket, OBJECT_KEY)
    print(f"Deleted: s3://{obs_bucket}/{OBJECT_KEY}")


if __name__ == "__main__":
    main()
