#!/usr/bin/env python3
"""
Power a CCE environment off and on to save costs, without deleting anything.

  stop   hibernate the cluster (masters are no longer billed), then stop all node ECS
  start  start the node ECS, wake up the cluster and wait until all nodes are Active
  status show cluster phase and node/ECS states (read-only)
  check  exit 3 if the cluster is powered off (Hibernating/Hibernation/Awaking), 0 otherwise (CI guard)

Usage:
  ./scripts/env-power.py status --cluster-id "$(tofu -chdir=infra output -raw cce_cluster_id)"

Stopped ECS are not billed for vCPU/memory/GPU (normal and GPU flavors such as
pi5e); EVS disks, EIPs, NAT and ELB keep being billed. GPU nodes that fail to
start (capacity) only produce a warning; re-run `start` later to retry them.

Credentials: TF_VAR_otc_access_key, TF_VAR_otc_secret_key, TF_VAR_otc_project_name (see otc_api.py).
"""
import argparse
import re
import sys
import time

from otc_api import call, host, project_id

CCE = host("cce")
ECS = host("ecs")
GPU_FLAVOR = re.compile(r"^(p|g)[a-z0-9]*\.")
POLL = 15
PID = HDR = None  # set in main()
POWERED_OFF = ("Hibernating", "Hibernation", "Awaking")


class PowerError(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def api(method, h, path, ok=(200,), body=None):
    status, data = call(method, h, path, headers=HDR, body=body)
    if status not in ok:
        raise PowerError(f"{method} {path}: HTTP {status}: {data}")
    return status, data


def cluster_phase(cid):
    status, data = call("GET", CCE, f"/api/v3/projects/{PID}/clusters/{cid}", headers=HDR)
    if status == 404:
        return None
    if status != 200:
        raise PowerError(f"Reading cluster {cid}: HTTP {status}: {data}")
    return data["status"]["phase"]


def nodes(cid):
    _, data = api("GET", CCE, f"/api/v3/projects/{PID}/clusters/{cid}/nodes")
    return [
        {
            "name": n["metadata"]["name"],
            "flavor": n["spec"]["flavor"],
            "phase": n.get("status", {}).get("phase", "?"),
            "server": n.get("status", {}).get("serverId", ""),
            "gpu": bool(GPU_FLAVOR.match(n["spec"]["flavor"])),
        }
        for n in data.get("items") or []
    ]


def server_status(sid):
    _, data = api("GET", ECS, f"/v1/{PID}/cloudservers/{sid}")
    return data["server"]["status"]


def wait(what, check, timeout):
    deadline = time.monotonic() + timeout
    while True:
        done, state = check()
        if done:
            log(f"  {what}: {state}")
            return state
        if time.monotonic() > deadline:
            raise PowerError(f"Timeout after {timeout}s waiting for {what} (last state: {state})")
        log(f"  {what}: {state} ...")
        time.sleep(POLL)


def ecs_action(action, servers):
    """Submit one ECS job per server (a failure stays isolated), wait for all. Returns failed servers."""
    jobs = {}
    for n in servers:
        spec = {"servers": [{"id": n["server"]}]}
        if action == "os-stop":
            spec["type"] = "SOFT"
        _, data = api("POST", ECS, f"/v1/{PID}/cloudservers/action", body={action: spec})
        jobs[data["job_id"]] = n
        log(f"  {action} {n['name']} ({n['flavor']}): job {data['job_id']}")

    failed = []
    deadline = time.monotonic() + 900
    pending = dict(jobs)
    while pending:
        for jid, n in list(pending.items()):
            _, data = api("GET", ECS, f"/v1/{PID}/jobs/{jid}")
            if data["status"] == "SUCCESS":
                log(f"  {n['name']}: done")
                del pending[jid]
            elif data["status"] == "FAIL":
                log(f"  {n['name']}: FAILED {data.get('fail_reason') or data.get('error_code') or ''}")
                failed.append(n)
                del pending[jid]
        if pending:
            if time.monotonic() > deadline:
                raise PowerError(f"Timeout waiting for ECS jobs: {', '.join(n['name'] for n in pending.values())}")
            time.sleep(POLL)
    return failed


def stop(cid):
    phase = cluster_phase(cid)
    if phase is None:
        raise PowerError(f"Cluster {cid} not found")
    # Read nodes before hibernation; the master is not needed for ECS actions.
    node_list = nodes(cid)

    if phase == "Available":
        log("Hibernating cluster")
        api("POST", CCE, f"/api/v3/projects/{PID}/clusters/{cid}/operation/hibernate")
    elif phase not in ("Hibernating", "Hibernation"):
        raise PowerError(f"Cluster is {phase}; refusing to hibernate")
    if phase != "Hibernation":
        wait("cluster", lambda: ((p := cluster_phase(cid)) == "Hibernation", p), 1800)

    running = []
    for n in node_list:
        if not n["server"]:
            continue
        state = server_status(n["server"])
        if state == "SHUTOFF":
            log(f"  {n['name']}: already SHUTOFF")
        elif state == "ACTIVE":
            running.append(n)
        else:
            log(f"::warning::{n['name']}: ECS is {state}, not stopping it")
    if running:
        log(f"Stopping {len(running)} node ECS")
        failed = ecs_action("os-stop", running)
        if failed:
            raise PowerError(f"Stopping failed: {', '.join(n['name'] for n in failed)}")


def start(cid):
    phase = cluster_phase(cid)
    if phase is None:
        raise PowerError(f"Cluster {cid} not found")
    if phase not in ("Available", "Awaking", "Hibernation"):
        raise PowerError(f"Cluster is {phase}; wait until it is Hibernation or Available")

    node_list = nodes(cid)
    stopped = []
    for n in node_list:
        if n["server"] and server_status(n["server"]) == "SHUTOFF":
            stopped.append(n)
    failed_gpu = []
    if stopped:
        log(f"Starting {len(stopped)} node ECS")
        failed = ecs_action("os-start", stopped)
        failed_gpu = [n for n in failed if n["gpu"]]
        hard = [n for n in failed if not n["gpu"]]
        for n in failed_gpu:
            log(f"::warning::GPU node {n['name']} did not start (capacity?); it still counts against the pool's max_count. "
                "Re-run Power -> start later to retry.")
        if hard:
            raise PowerError(f"Starting failed: {', '.join(n['name'] for n in hard)}")

    if phase == "Hibernation":
        log("Waking up cluster")
        api("POST", CCE, f"/api/v3/projects/{PID}/clusters/{cid}/operation/awake")
    if phase != "Available":
        wait("cluster", lambda: ((p := cluster_phase(cid)) == "Available", p), 1800)

    skip = {n["name"] for n in failed_gpu}

    def all_active():
        current = [n for n in nodes(cid) if n["name"] not in skip]
        pending = [f"{n['name']}={n['phase']}" for n in current if n["phase"] != "Active"]
        return not pending, ", ".join(pending) or f"{len(current)} Active"

    wait("nodes", all_active, 1200)


def summary(cid, out):
    phase = cluster_phase(cid)
    lines = [f"## Environment power: cluster `{phase or 'not found'}`", ""]
    if phase is not None:
        lines += ["| Node | Flavor | CCE phase | ECS |", "|---|---|---|---|"]
        for n in nodes(cid):
            ecs = server_status(n["server"]) if n["server"] else "-"
            lines.append(f"| {n['name']} | {n['flavor']}{' (GPU)' if n['gpu'] else ''} | {n['phase']} | {ecs} |")
    text = "\n".join(lines) + "\n"
    print(text)
    if out:
        with open(out, "a") as f:
            f.write(text)


def cluster_id(value):
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value):
        raise argparse.ArgumentTypeError(f"not a CCE cluster ID: {value[:60]!r}")
    return value


def main():
    global PID, HDR
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["status", "stop", "start", "check"])
    parser.add_argument("--cluster-id", required=True, type=cluster_id)
    parser.add_argument("--summary", default="", help="append a markdown summary to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = parser.parse_args()

    PID = project_id()
    HDR = {"x-project-id": PID}
    try:
        if args.action == "check":
            phase = cluster_phase(args.cluster_id)
            log(f"Cluster {args.cluster_id}: {phase or 'not found'}")
            if phase in POWERED_OFF:
                log("Environment is powered off. Run Actions -> Power -> start first.")
                sys.exit(3)
            return
        if args.action == "stop":
            stop(args.cluster_id)
        elif args.action == "start":
            start(args.cluster_id)
        summary(args.cluster_id, args.summary)
    except PowerError as e:
        log(f"::error::{e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
