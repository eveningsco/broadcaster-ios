#!/usr/bin/env python3
"""Trigger the "Simulator Screenshots" GitHub Actions workflow, wait for it,
and download the PNGs — from any machine with python3 and a GitHub token
(no Xcode, no gh CLI needed).

    GH_TOKEN=... scripts/ci-screenshots.py [--ref BRANCH] [--scenes "login live"]
                                           [--device "iPhone 16 Pro"]
                                           [--appearance light|dark|both]
                                           [--out screenshots]

The token needs `repo` scope (or Actions read/write on a fine-grained token).
Defaults to the current git branch. Exits non-zero if the run fails; the
workflow uploads an `xcodebuild-log` artifact in that case.
"""
import argparse
import datetime as dt
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = os.environ.get("GITHUB_REPOSITORY", "eveningsco/broadcaster-ios")
WORKFLOW = "simulator-screenshots.yml"
API = "https://api.github.com"


def token():
    for key in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(key):
            return os.environ[key]
    sys.exit("set GH_TOKEN (repo scope)")


def request(path, method="GET", body=None, raw=False):
    url = path if path.startswith("http") else f"{API}/repos/{REPO}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "broadcaster-ios-ci-screenshots",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> {e.code}: {e.read().decode(errors='replace')[:400]}")
    if raw or not payload:
        return payload
    return json.loads(payload)


def current_branch():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True
        ).strip()
    except Exception:
        return "main"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ref", default=current_branch())
    p.add_argument("--scenes", default="login library explore stage live")
    p.add_argument("--device", default="iPhone 16 Pro")
    p.add_argument("--appearance", default="light", choices=["light", "dark", "both"])
    p.add_argument("--out", default="screenshots")
    p.add_argument("--timeout", type=int, default=45 * 60, help="seconds to wait for the run")
    args = p.parse_args()

    started = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5)
    try:
        request(f"/actions/workflows/{WORKFLOW}/dispatches", "POST", {
            "ref": args.ref,
            "inputs": {"scenes": args.scenes, "device": args.device, "appearance": args.appearance},
        })
    except SystemExit as e:
        if "-> 404" in str(e):
            sys.exit(f"{e}\n\nGitHub returned 404 for the dispatch. A dispatch-only workflow is only "
                     f"registered once its file exists on the repo's default branch; "
                     f"land .github/workflows/{WORKFLOW} on main (one commit, just that file), "
                     f"then re-run with --ref {args.ref}.")
        raise
    print(f"dispatched {WORKFLOW} on {args.ref}; waiting for the run to appear…")

    run = None
    deadline = time.time() + args.timeout
    while run is None and time.time() < deadline:
        time.sleep(5)
        runs = request(f"/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch"
                       f"&branch={args.ref}&per_page=5")["workflow_runs"]
        fresh = [r for r in runs
                 if dt.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00")) >= started]
        if fresh:
            run = fresh[0]
    if run is None:
        sys.exit("run never appeared")
    print(f"run {run['id']}: {run['html_url']}")

    last = None
    while time.time() < deadline:
        run = request(f"/actions/runs/{run['id']}")
        label = f"{run['status']}/{run['conclusion']}"
        if label != last:
            print(f"  {label}")
            last = label
        if run["status"] == "completed":
            break
        time.sleep(15)
    else:
        sys.exit("timed out waiting for the run")

    artifacts = request(f"/actions/runs/{run['id']}/artifacts")["artifacts"]
    os.makedirs(args.out, exist_ok=True)
    for artifact in artifacts:
        blob = request(artifact["archive_download_url"], raw=True)
        names = []
        with zipfile.ZipFile(io.BytesIO(blob)) as zf:
            zf.extractall(args.out)
            names = zf.namelist()
        print(f"downloaded {artifact['name']}: {', '.join(sorted(names))} -> {args.out}/")

    if run["conclusion"] != "success":
        sys.exit(f"run finished with conclusion={run['conclusion']}")


if __name__ == "__main__":
    main()
