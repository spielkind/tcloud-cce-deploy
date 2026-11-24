#!/usr/bin/env python3
"""
Remove leftovers that block `tofu destroy` of the infra project.

- SWR organizations cannot be deleted while they contain repositories.

Run before the infra destroy:
  ./scripts/destroy-cleanup.py --swr-org <org>

The VM module (own VPC, NAT, ELB, ECS, versioned OBS bucket with force_destroy)
is removed completely by `tofu destroy` and needs no cleanup.

Credentials: TF_VAR_otc_access_key, TF_VAR_otc_secret_key, TF_VAR_otc_project_name.
"""
import argparse
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


def cleanup_swr(org, headers):
    host = f"swr-api.{REGION}.otc.t-systems.com"
    status, repos = call("GET", host, "/v2/manage/repos", {"namespace": org}, headers)
    if status == 404:
        # Only an object-specific not-found means the organization is gone.
        code, _ = call("GET", host, f"/v2/manage/namespaces/{urllib.parse.quote(org, safe='')}", None, headers)
        if code == 404:
            print(f"SWR: organization {org} already removed")
            return True
    if status != 200 or not isinstance(repos, list):
        print(f"SWR: could not verify repositories of {org} (HTTP {status})", file=sys.stderr)
        return False
    ok = True
    for repo in repos:
        name = urllib.parse.quote(repo["name"], safe="")
        code, body = call("DELETE", host, f"/v2/manage/namespaces/{org}/repos/{name}", None, headers)
        if code in (200, 204, 404):
            print(f"SWR: deleted repository {org}/{repo['name']}")
        else:
            ok = False
            print(f"SWR: delete {org}/{repo['name']} failed (HTTP {code}): {body}", file=sys.stderr)
    if not repos:
        print(f"SWR: organization {org} has no repositories")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--swr-org", default="", help="SWR organization to empty")
    args = parser.parse_args()

    if not args.swr_org:
        print("SWR: no organization given, nothing to clean up")
        return
    sys.exit(0 if cleanup_swr(args.swr_org, {"x-project-id": project_id()}) else 1)


if __name__ == "__main__":
    main()
