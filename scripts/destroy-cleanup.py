#!/usr/bin/env python3
"""
Remove leftovers that block `tofu destroy` of the infra project.

- FunctionGraph VPC access ports ("FunctionGraph-Access-VPC-Port") stay in the
  node subnet after the function is deleted and block subnet/VPC deletion.
- SWR organizations cannot be deleted while they contain repositories.

Run after the FunctionGraph function is destroyed and before the full destroy:
  ./scripts/destroy-cleanup.py --network-id <subnet network id> --swr-org <org>

Credentials: TF_VAR_otc_access_key, TF_VAR_otc_secret_key, TF_VAR_otc_project_name.
"""
import argparse
import datetime
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REGION = "eu-de"
FG_PORT_NAME = "FunctionGraph-Access-VPC-Port"

AK = os.environ.get("TF_VAR_otc_access_key") or sys.exit("Set TF_VAR_otc_access_key")
SK = os.environ.get("TF_VAR_otc_secret_key") or sys.exit("Set TF_VAR_otc_secret_key")
PROJECT_NAME = os.environ.get("TF_VAR_otc_project_name") or sys.exit("Set TF_VAR_otc_project_name")


def call(method, host, path, query=None, headers=None):
    """Signed OTC API request (SDK-HMAC-SHA256). Returns (status, parsed body)."""
    q = urllib.parse.urlencode(sorted((query or {}).items()))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    h = {"host": host, "x-sdk-date": stamp, "content-type": "application/json", **(headers or {})}
    signed = ";".join(sorted(h))
    canonical = (
        f"{method}\n{path}{'' if path.endswith('/') else '/'}\n{q}\n"
        + "".join(f"{k}:{h[k]}\n" for k in sorted(h))
        + f"\n{signed}\n{hashlib.sha256(b'').hexdigest()}"
    )
    to_sign = f"SDK-HMAC-SHA256\n{stamp}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
    signature = hmac.new(SK.encode(), to_sign.encode(), hashlib.sha256).hexdigest()
    auth = f"SDK-HMAC-SHA256 Access={AK}, SignedHeaders={signed}, Signature={signature}"
    url = f"https://{host}{path}" + (f"?{q}" if q else "")
    req = urllib.request.Request(url, method=method, headers={**h, "Authorization": auth})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            return resp.status, json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


def project_id():
    status, data = call("GET", f"iam.{REGION}.otc.t-systems.com", "/v3/projects", {"name": PROJECT_NAME})
    if status != 200 or not data.get("projects"):
        sys.exit(f"Could not resolve project {PROJECT_NAME}: HTTP {status}")
    return data["projects"][0]["id"]


def cleanup_fg_ports(network_id, headers, timeout):
    host = f"vpc.{REGION}.otc.t-systems.com"
    deadline = time.monotonic() + timeout
    while True:
        status, data = call("GET", host, "/v2.0/ports", {"network_id": network_id}, headers)
        if status != 200:
            print(f"Ports: could not list ports in {network_id} (HTTP {status}), skipping")
            return True
        fg_ports = [p for p in data.get("ports", []) if p.get("name") == FG_PORT_NAME]
        if not fg_ports:
            print("Ports: no FunctionGraph ports left")
            return True
        for port in fg_ports:
            # Only ports no longer attached to anything; attached ones are released by FunctionGraph first.
            if port.get("device_id") or port.get("device_owner"):
                continue
            code, body = call("DELETE", host, f"/v2.0/ports/{port['id']}", None, headers)
            ok = code in (200, 204, 404)
            print(f"Ports: deleted {port['id']}" if ok else f"Ports: delete {port['id']} failed (HTTP {code}): {body}")
        if time.monotonic() > deadline:
            print(f"Ports: FunctionGraph ports still present after {timeout}s", file=sys.stderr)
            return False
        time.sleep(10)


def cleanup_swr(org, headers):
    host = f"swr-api.{REGION}.otc.t-systems.com"
    status, repos = call("GET", host, "/v2/manage/repos", {"namespace": org}, headers)
    if status != 200 or not isinstance(repos, list):
        print(f"SWR: could not list repositories of {org} (HTTP {status}), skipping")
        return True
    ok = True
    for repo in repos:
        name = urllib.parse.quote(repo["name"], safe="")
        code, body = call("DELETE", host, f"/v2/manage/namespaces/{org}/repos/{name}", None, headers)
        if code in (200, 204):
            print(f"SWR: deleted repository {org}/{repo['name']}")
        else:
            ok = False
            print(f"SWR: delete {org}/{repo['name']} failed (HTTP {code}): {body}", file=sys.stderr)
    if not repos:
        print(f"SWR: organization {org} has no repositories")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--network-id", default="", help="Neutron network ID of the node subnet")
    parser.add_argument("--swr-org", default="", help="SWR organization to empty")
    parser.add_argument("--timeout", type=int, default=300, help="Seconds to wait for FunctionGraph ports")
    args = parser.parse_args()

    headers = {"x-project-id": project_id()}
    ok = True
    if args.network_id:
        ok &= cleanup_fg_ports(args.network_id, headers, args.timeout)
    if args.swr_org:
        ok &= cleanup_swr(args.swr_org, headers)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
