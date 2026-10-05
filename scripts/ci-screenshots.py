#!/usr/bin/env python3
"""Trigger the "Simulator Screenshots" GitHub Actions workflow, wait for it,
and download the PNGs — from any machine with python3 and a GitHub token
(no Xcode, no gh CLI needed).

    GH_TOKEN=... scripts/ci-screenshots.py [--ref BRANCH] [--scenes auto|"login live"]
                                           [--device "iPhone 16 Pro"]
                                           [--appearance light|dark|both]
                                           [--out screenshots] [--dry-run] [--force]
    GH_TOKEN=... scripts/ci-screenshots.py --run 37172713333   # attach to an existing run
    GH_TOKEN=... scripts/ci-screenshots.py --scenes edit-demo    # ~18 s recording as animated PNG
    GH_TOKEN=... scripts/ci-screenshots.py --scenes track-demo   # cover tap → detail card hero transition

Every run is a macOS job billed at 10x, and the build (~6-12 min) costs far
more than the scenes (~5-10 s per still), so the script works hard to not
start runs:

  1. Scenes default to `auto`: only the scenes the branch's changes touch since
     its last full screenshot run (scripts/ci/screenshot-scenes.txt maps files
     to scenes). No visual changes → nothing is dispatched. `-demo` recordings
     are only captured when named explicitly.
  2. Reuse: a successful run of the same commit, device and appearance that
     already covers the scenes is downloaded instead of re-run.
  3. Coalesce: if a run for the branch is already queued or running, the
     script waits for it rather than stacking a second one, then re-plans so
     anything pushed meanwhile goes into one follow-up run.
  4. Throttle: at most one new run per branch every 15 minutes and 10 per
     branch per 24 hours (SCREENSHOTS_COOLDOWN_MIN / SCREENSHOTS_DAILY_MAX).
     When throttled it exits with status 3 and says when the next run is
     allowed: keep working and batch more changes into that run. --force
     skips the throttle (not the reuse or coalescing).

The token needs `repo` scope (or Actions read/write plus Contents read on a
fine-grained token). Defaults to the current git branch. Exits non-zero if the
run fails; the workflow uploads an `xcodebuild-log` artifact in that case.
"""
import argparse
import datetime as dt
import fnmatch
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
HERE = os.path.dirname(os.path.abspath(__file__))
SCENE_MAP = os.path.join(HERE, "ci", "screenshot-scenes.txt")

# Keep in step with ScreenshotMode.Scene (Sources/Debug/ScreenshotMode.swift).
STILLS = ["login", "signup", "library", "explore", "account", "edit", "track", "stage", "live"]
DEMOS = ["edit-demo", "track-demo", "page-demo"]

COOLDOWN = dt.timedelta(minutes=float(os.environ.get("SCREENSHOTS_COOLDOWN_MIN", 15)))
DAILY_MAX = int(os.environ.get("SCREENSHOTS_DAILY_MAX", 10))
THROTTLED = 3  # exit status when the cooldown or daily budget blocks a run


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


class APIError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def request(path, method="GET", body=None, raw=False, fatal=True):
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
        message = f"{method} {url} -> {e.code}: {e.read().decode(errors='replace')[:400]}"
        if fatal:
            sys.exit(message)
        raise APIError(e.code, message)
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


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def now():
    return dt.datetime.now(dt.timezone.utc)


# --- Scene selection ---------------------------------------------------------

def load_scene_map(path=SCENE_MAP):
    rules = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            glob, *scenes = line.split()
            rules.append((glob, scenes))
    return rules


def scenes_for_files(files, rules):
    """Scenes affected by `files`, in STILLS order, plus why each was picked."""
    picked, why = set(), {}
    for path in files:
        target = None
        for glob, scenes in rules:
            if fnmatch.fnmatchcase(path, glob):
                target = scenes
                break
        if target is None:
            target = ["ALL"]  # unmapped files are assumed to affect everything
        if target == ["NONE"]:
            continue
        hit = STILLS if "ALL" in target else target
        for scene in hit:
            picked.add(scene)
            why.setdefault(scene, path)
    return [s for s in STILLS if s in picked], why


def changed_files(base_sha, head_sha):
    """Files changed between two commits, via the compare API (no local clone
    needed). None if the base is unknown to GitHub (e.g. force-pushed away)."""
    files, page = [], 1
    while True:
        try:
            cmp = request(f"/compare/{base_sha}...{head_sha}?per_page=100&page={page}", fatal=False)
        except APIError:
            return None
        batch = [f["filename"] for f in cmp.get("files", [])]
        # Renames touch both paths.
        batch += [f["previous_filename"] for f in cmp.get("files", []) if f.get("previous_filename")]
        files += batch
        if len(cmp.get("files", [])) < 100 or page >= 30:
            return files
        page += 1


# --- Past runs ---------------------------------------------------------------
# Runs are titled by the workflow's `run-name`:
#   "Screenshots: <scenes> · <appearance> · <device>"
# Runs from before that existed are titled "Simulator Screenshots" and are
# treated as having captured all stills (the old default).

def describe(run):
    title = run.get("display_title") or ""
    if title.startswith("Screenshots: "):
        parts = [p.strip() for p in title[len("Screenshots: "):].split("·")]
        if len(parts) == 3:
            return {"scenes": set(parts[0].split()), "appearance": parts[1], "device": parts[2]}
    return {"scenes": set(STILLS), "appearance": None, "device": None}


def branch_runs(ref):
    return request(f"/actions/workflows/{WORKFLOW}/runs?branch={urllib.parse.quote(ref)}"
                   f"&event=workflow_dispatch&per_page=50")["workflow_runs"]


def head_sha(ref):
    return request(f"/commits/{urllib.parse.quote(ref)}")["sha"]


def plan(args):
    """Decide what to do. Returns one of:
       ("wait", run)            a run for this branch is in flight; wait for it, then re-plan
       ("reuse", run)           an identical successful run exists; download it
       ("nothing", message)     no scene needs capturing
       ("throttled", message)   cooldown / daily budget says not now
       ("dispatch", scenes, reasons)
    """
    sha = head_sha(args.ref)
    runs = branch_runs(args.ref)

    active = [r for r in runs if r["status"] != "completed"]
    if active:
        return ("wait", active[-1])  # the oldest in flight; later ones queue behind it

    if args.scenes.strip() == "auto":
        full = [r for r in runs if r["conclusion"] == "success"
                and set(STILLS) <= describe(r)["scenes"]]
        if not full:
            scenes, reasons = STILLS, {s: "no full screenshot run on this branch yet" for s in STILLS}
        else:
            base = full[0]  # newest first
            if base["head_sha"] == sha:
                return ("nothing", f"run {base['id']} already captured all scenes at {sha[:7]}")
            files = changed_files(base["head_sha"], sha)
            if files is None:
                scenes = STILLS
                reasons = {s: f"can't diff against {base['head_sha'][:7]}" for s in STILLS}
            else:
                scenes, reasons = scenes_for_files(files, load_scene_map())
                if not scenes:
                    return ("nothing", f"no file changed since {base['head_sha'][:7]} "
                                       f"(run {base['id']}) affects a scene")
    else:
        scenes = args.scenes.split()
        unknown = [s for s in scenes if s not in STILLS + DEMOS]
        if unknown:
            sys.exit(f"unknown scene(s): {' '.join(unknown)}; known: {' '.join(STILLS + DEMOS)}")
        reasons = {s: "requested" for s in scenes}

    for r in runs:
        d = describe(r)
        if (r["conclusion"] == "success" and r["head_sha"] == sha and set(scenes) <= d["scenes"]
                and d["appearance"] in (None, args.appearance) and d["device"] in (None, args.device)):
            return ("reuse", r)

    if not args.force:
        recent = [r for r in runs if now() - parse_time(r["created_at"]) < dt.timedelta(hours=24)]
        if len(recent) >= DAILY_MAX:
            oldest = min(parse_time(r["created_at"]) for r in recent)
            return ("throttled", f"{len(recent)} screenshot runs on {args.ref} in the last 24 h "
                                 f"(max {DAILY_MAX}); next allowed at "
                                 f"{(oldest + dt.timedelta(hours=24)):%H:%M} UTC")
        if runs:
            last = parse_time(runs[0]["created_at"])
            if now() - last < COOLDOWN:
                return ("throttled", f"last run on {args.ref} started {(now() - last).seconds // 60} min ago; "
                                     f"next allowed at {(last + COOLDOWN):%H:%M} UTC "
                                     f"(cooldown {COOLDOWN.seconds // 60} min)")
    return ("dispatch", scenes, reasons)


# --- Main --------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ref", default=current_branch())
    p.add_argument("--scenes", default="auto",
                   help='"auto" (scenes touched since the last full run) or space-separated scenes; '
                        "ones ending in -demo are recorded (animated PNG)")
    p.add_argument("--device", default="iPhone 16 Pro")
    p.add_argument("--appearance", default="dark", choices=["light", "dark", "both"])
    p.add_argument("--out", default="screenshots")
    p.add_argument("--timeout", type=int, default=45 * 60, help="seconds to wait for the run")
    p.add_argument("--run", type=int, metavar="RUN_ID",
                   help="don't dispatch; wait for this existing run (e.g. one started from the Actions tab)")
    p.add_argument("--dry-run", action="store_true", help="print what would happen and exit")
    p.add_argument("--force", action="store_true", help="ignore the cooldown and daily budget")
    args = p.parse_args()

    deadline = time.time() + args.timeout
    if args.run:
        run = request(f"/actions/runs/{args.run}")
        print(f"attached to run {run['id']} ({run['head_branch']} @ {run['head_sha'][:7]}): {run['html_url']}")
        finish(wait(run, deadline), args)
        return

    while True:
        decision = plan(args)
        kind = decision[0]
        if kind == "wait":
            run = decision[1]
            print(f"run {run['id']} is already {run['status']} on {args.ref} "
                  f"@ {run['head_sha'][:7]}; waiting for it instead of starting another: {run['html_url']}")
            if args.dry_run:
                return
            wait(run, deadline)
            continue  # re-plan: anything pushed meanwhile goes into one follow-up run
        if kind == "reuse":
            run = decision[1]
            print(f"run {run['id']} already captured these scenes at {run['head_sha'][:7]}; "
                  f"downloading it: {run['html_url']}")
            if not args.dry_run:
                finish(run, args)
            return
        if kind == "nothing":
            print(f"nothing to capture: {decision[1]}")
            return
        if kind == "throttled":
            print(f"not starting a run: {decision[1]}.\n"
                  f"Keep working and batch more changes into the next run, "
                  f"or pass --force if this one can't wait.", file=sys.stderr)
            sys.exit(THROTTLED)
        _, scenes, reasons = decision
        print(f"scenes: {' '.join(scenes)}")
        for s in scenes:
            print(f"  {s:<10} {reasons.get(s, '')}")
        if args.dry_run:
            return
        run = dispatch_and_find_run(args, scenes, deadline)
        finish(wait(run, deadline), args)
        return


def wait(run, deadline):
    last = None
    while time.time() < deadline:
        run = request(f"/actions/runs/{run['id']}")
        label = f"{run['status']}/{run['conclusion']}"
        if label != last:
            print(f"  {label}")
            last = label
        if run["status"] == "completed":
            return run
        time.sleep(15)
    sys.exit("timed out waiting for the run")


def finish(run, args):
    artifacts = request(f"/actions/runs/{run['id']}/artifacts")["artifacts"]
    os.makedirs(args.out, exist_ok=True)
    for artifact in artifacts:
        if artifact.get("expired"):
            print(f"artifact {artifact['name']} has expired")
            continue
        blob = request(artifact["archive_download_url"], raw=True)
        with zipfile.ZipFile(io.BytesIO(blob)) as zf:
            zf.extractall(args.out)
            names = zf.namelist()
        print(f"downloaded {artifact['name']}: {', '.join(sorted(names))} -> {args.out}/")

    if run["conclusion"] != "success":
        sys.exit(f"run finished with conclusion={run['conclusion']}")


def dispatch_and_find_run(args, scenes, deadline):
    started = now() - dt.timedelta(seconds=5)
    try:
        request(f"/actions/workflows/{WORKFLOW}/dispatches", "POST", {
            "ref": args.ref,
            "inputs": {"scenes": " ".join(scenes), "device": args.device, "appearance": args.appearance},
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
                       f"&branch={urllib.parse.quote(args.ref)}&per_page=5")["workflow_runs"]
        fresh = [r for r in runs if parse_time(r["created_at"]) >= started]
        if fresh:
            run = fresh[0]
    if run is None:
        sys.exit("run never appeared")
    print(f"run {run['id']}: {run['html_url']}")
    return run


if __name__ == "__main__":
    main()
