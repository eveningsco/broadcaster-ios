#!/usr/bin/env python3
"""Trigger the "Simulator Screenshots" GitHub Actions workflow, wait for it,
and download the PNGs — from any machine with python3 and a GitHub token
(no Xcode, no gh CLI needed).

    GH_TOKEN=... scripts/ci-screenshots.py [--ref BRANCH] [--scenes "login live"]
                                           [--device "iPhone 16 Pro"]
                                           [--appearance light|dark|both]
                                           [--out screenshots]
    GH_TOKEN=... scripts/ci-screenshots.py --run 37172713333   # attach to an existing run

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
import urllib.parse
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


class _DropAuthOnCrossHostRedirect(urllib.request.HTTPRedirectHandler):
    """Artifact downloads 302 from api.github.com to Azure blob storage, which
    rejects requests that still carry the GitHub bearer token (401
    InvalidAuthenticationInfo). urllib forwards headers on redirect, so strip
    Authorization when the host changes."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            new.remove_header("Authorization")
        return new


_opener = urllib.request.build_opener(_DropAuthOnCrossHostRedirect)


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
        with _opener.open(req) as resp:
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
    p.add_argument("--run", type=int, metavar="RUN_ID",
                   help="don't dispatch; wait for this existing run (e.g. one started from the Actions tab)")
    args = p.parse_args()

    deadline = time.time() + args.timeout
    if args.run:
        run = request(f"/actions/runs/{args.run}")
        print(f"attached to run {run['id']} ({run['head_branch']} @ {run['head_sha'][:7]}): {run['html_url']}")
    else:
        run = dispatch_and_find_run(args, deadline)

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


def dispatch_and_find_run(args, deadline):
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
    return run


if __name__ == "__main__":
    main()
