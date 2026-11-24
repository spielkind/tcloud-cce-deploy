#!/usr/bin/env python3
"""
Store the OpenBao unseal keys for the auto-unseal sidecar (cce mode).

Encrypts the shares with the infra KMS key and writes only the ciphertext to
the Kubernetes Secret openbao/openbao-unseal-keys (key keys.enc).

Safety checks (all against the infra state of TF_VAR_environment):
- the state belongs to TF_VAR_environment / TF_VAR_otc_project_name, cce mode;
- the key file (written by openbao-init.sh) names this environment and the
  CCE cluster ID; files from before that binding need --legacy-source-cluster-id
  with the independently verified ORIGINAL cluster ID;
- the Secret is written to the cluster from the infra state; a set KUBECONFIG
  must point to the same API endpoint and CA.

Usage:
  TF_VAR_environment=dev ./scripts/upload-unseal-keys.py <openbao-keys-file>
  TF_VAR_environment=dev ./scripts/upload-unseal-keys.py  (reads from stdin)
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

NAMESPACE = "openbao"
SECRET_NAME = "openbao-unseal-keys"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INFRA_DIR = os.path.join(SCRIPT_DIR, "..", "infra")

AK = os.environ.get("TF_VAR_otc_access_key") or sys.exit("Set TF_VAR_otc_access_key")
SK = os.environ.get("TF_VAR_otc_secret_key") or sys.exit("Set TF_VAR_otc_secret_key")
PROJECT_NAME = os.environ.get("TF_VAR_otc_project_name") or sys.exit("Set TF_VAR_otc_project_name")


def infra_target():
    """Outputs of the infra state, checked against environment and project."""
    env = os.environ.get("TF_VAR_environment")
    if env not in {"dev", "prod"}:
        sys.exit("Set TF_VAR_environment to dev or prod")
    outputs = json.loads(subprocess.check_output(["tofu", "output", "-json"], cwd=INFRA_DIR))
    target = {k: outputs.get(k, {}).get("value") for k in (
        "environment", "cce_cluster_id", "openbao_mode", "openbao_unseal_kms_key_id", "otc_project_name", "region",
        "kubeconfig")}
    if not all(isinstance(v, str) and v for v in target.values()):
        sys.exit("Infra state incomplete (create_openbao_unseal in cce mode applied? infra/ initialized for this environment?)")
    if target["openbao_mode"] != "cce" or target["environment"] != env or target["otc_project_name"] != PROJECT_NAME:
        sys.exit(f"Infra state ({target['environment']}, {target['otc_project_name']}, {target['openbao_mode']}) "
                 f"does not match TF_VAR_environment={env} / TF_VAR_otc_project_name in cce mode")
    return target


def check_key_file(content, target, legacy_cluster):
    clusters = re.findall(r"^CCE Cluster ID: (\S+)$", content, re.M)
    environments = re.findall(r"^Environment: (\S+)$", content, re.M)
    if not clusters and not environments and legacy_cluster:
        clusters, environments = [legacy_cluster], [target["environment"]]
    if clusters != [target["cce_cluster_id"]] or environments != [target["environment"]]:
        sys.exit("Key file is not bound to this environment/cluster "
                 f"(expected {target['environment']} / {target['cce_cluster_id']}). "
                 "For files from before the binding, verify the original cluster ID and pass --legacy-source-cluster-id.")


THRESHOLD = 3  # key threshold used by openbao-init.sh (5 shares, 3 required)


def parse_unseal_keys(content):
    """Unseal shares from an openbao.keys.* file: at least THRESHOLD valid, distinct shares with unique numbers.

    An incomplete set would replace a working Secret and only fail at the next pod restart."""
    entries = re.findall(r"^Unseal Key (\d+):\s*(\S+)\s*$", content, re.M)
    numbers = [int(n) for n, _ in entries]
    shares = [k for _, k in entries]
    if len(set(numbers)) != len(numbers):
        sys.exit("Duplicate 'Unseal Key <n>' numbers in the key file")
    if len(set(shares)) != len(shares):
        sys.exit("Identical unseal shares in the key file")
    for n, k in entries:
        try:
            if len(base64.b64decode(k, validate=True)) < 16:
                raise ValueError
        except ValueError:
            sys.exit(f"Unseal Key {n} is not a valid base64 share")
    if len(shares) < THRESHOLD:
        sys.exit(f"Only {len(shares)} unseal share(s) found; at least {THRESHOLD} distinct shares are required")
    return shares


def get_token_and_project_id(region):
    body = json.dumps({"auth": {
        "identity": {"methods": ["hw_ak_sk"], "hw_ak_sk": {"access": {"key": AK}, "secret": {"key": SK}}},
        "scope": {"project": {"name": PROJECT_NAME}}}})
    req = Request(f"https://iam.{region}.otc.t-systems.com/v3/auth/tokens", data=body.encode(), method="POST",
                  headers={"Content-Type": "application/json"})
    with urlopen(req) as resp:
        return resp.headers.get("X-Subject-Token"), json.loads(resp.read())["token"]["project"]["id"]


def cluster_identity(kubeconfig):
    """API endpoint + CA of the current context."""
    out = subprocess.check_output(["kubectl", "config", "view", "--minify", "--raw", "--flatten", "-o", "json"],
                                  env={**os.environ, "KUBECONFIG": kubeconfig})
    clusters = json.loads(out).get("clusters") or []
    if len(clusters) != 1:
        return None
    c = clusters[0]["cluster"]
    return c.get("server"), c.get("certificate-authority-data")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", nargs="?", help="openbao.keys.* file from openbao-init.sh (default: stdin)")
    parser.add_argument("--legacy-source-cluster-id", help="verified ORIGINAL cluster ID of a key file without binding")
    args = parser.parse_args()

    target = infra_target()
    if args.file:
        with open(args.file) as f:
            content = f.read()
    else:
        print("Paste openbao.keys content (Ctrl+D when done):")
        content = sys.stdin.read()
    check_key_file(content, target, args.legacy_source_cluster_id)
    unseal_keys = parse_unseal_keys(content)
    print(f"Found {len(unseal_keys)} unseal keys for {target['environment']} / cluster {target['cce_cluster_id']}")

    fd, kubeconfig = tempfile.mkstemp(suffix=".kubeconfig")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(target["kubeconfig"])
        expected = cluster_identity(kubeconfig)
        if os.environ.get("KUBECONFIG"):
            try:
                actual = cluster_identity(os.environ["KUBECONFIG"])
            except (subprocess.CalledProcessError, ValueError):
                actual = None
            if not expected or actual != expected:
                sys.exit("KUBECONFIG points to a different cluster than the infra state; refusing.")

        region = target["region"]
        token, project_id = get_token_and_project_id(region)
        print("\n=== Encrypting unseal keys (KMS) ===")
        body = json.dumps({"key_id": target["openbao_unseal_kms_key_id"],
                           "plain_text": base64.b64encode(",".join(unseal_keys).encode()).decode()})
        req = Request(f"https://kms.{region}.otc.t-systems.com/v1.0/{project_id}/kms/encrypt-data",
                      data=body.encode(), method="POST",
                      headers={"X-Auth-Token": token, "Content-Type": "application/json"})
        with urlopen(req) as resp:
            cipher_text = json.loads(resp.read()).get("cipher_text", "")
        if not cipher_text:
            sys.exit("Encryption failed (no cipher_text in KMS response)")

        print(f"=== Writing Secret {NAMESPACE}/{SECRET_NAME} ===")
        env = {**os.environ, "KUBECONFIG": kubeconfig}
        manifest = json.loads(subprocess.run(
            ["kubectl", "-n", NAMESPACE, "create", "secret", "generic", SECRET_NAME,
             "--from-file=keys.enc=/dev/stdin", "--dry-run=client", "-o", "json"],
            input=cipher_text, capture_output=True, text=True, env=env, check=True).stdout)
        manifest["metadata"]["annotations"] = {
            "openbao.unseal/environment": target["environment"],
            "openbao.unseal/cce-cluster-id": target["cce_cluster_id"],
            "openbao.unseal/kms-key-id": target["openbao_unseal_kms_key_id"],
        }
        subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(manifest), text=True, env=env, check=True)
    finally:
        os.unlink(kubeconfig)

    print(f"\nSUCCESS: {len(unseal_keys)} unseal keys encrypted and stored in {NAMESPACE}/{SECRET_NAME}")
    print("The auto-unseal sidecar of each OpenBao pod picks it up within about a minute.")


if __name__ == "__main__":
    main()
