#!/usr/bin/env python3
"""
Remove leftovers that block `tofu destroy` of the infra project.

- SWR organizations cannot be deleted while they contain repositories.

Run before the infra destroy:
  ./scripts/destroy-cleanup.py --swr-org <org>

The VM module (own VPC, NAT, ELB, ECS, versioned OBS bucket with force_destroy)
is removed completely by `tofu destroy` and needs no cleanup.

Credentials: TF_VAR_otc_access_key, TF_VAR_otc_secret_key, TF_VAR_otc_project_name (see otc_api.py).
"""
import argparse
import sys
import urllib.parse

from otc_api import REGION, call, project_id


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
