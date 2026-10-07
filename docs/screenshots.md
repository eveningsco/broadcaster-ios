# Screenshots and recordings

You don't need a Mac to see the app. The **Simulator Screenshots** GitHub Actions workflow builds the app on a macOS runner, boots an iPhone simulator, and captures each screen as a PNG.

## Capturing from any machine

You need `python3` and a GitHub token with `repo` scope.

```sh
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch            # scenes your changes touch
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch --dry-run  # what it would do, without doing it
GH_TOKEN=... scripts/ci-screenshots.py --scenes "login stage"     # exactly these scenes
# → screenshots/<scene>.png
```

You can also start a run by hand (Actions → **Simulator Screenshots** → **Run workflow**) and download the `simulator-screenshots` artifact. A cold run takes about 8–12 minutes, most of it spent resolving packages and building.

## Scenes

The app has a debug-only **screenshot mode**: launched with `-screenshot <scene>`, it renders that scene from fixture data (`Sources/Debug/ScreenshotMode.swift`), with no account, network, Keychain or microphone involved. It's compiled out of Release builds.

| Scene | What it shows |
| --- | --- |
| `login` | The sign-in form |
| `signup` | Account creation |
| `library` | Home, with the Library tab over the stage |
| `explore` | Home, with the Explore tab |
| `account` | The account sheet (station photo, name, sign out) |
| `edit` | The trim and tempo editor over the library |
| `track` | The track detail card over the library |
| `stage` | The stage, idle, ready to go live |
| `live` | The stage on air, with the timer running |

Scenes ending in `-demo` animate instead of posing, and the capture script records them (`simctl io recordVideo`) into `<scene>.mov` plus an animated `<scene>.png`:

- `edit-demo`: the editor trims, auditions and re-speeds a track by itself, with a ghost fingertip.
- `track-demo`: a track's cover flies out of its row into the detail card, which is then dismissed. It runs at half speed so the roughly 15 fps CI simulator catches the motion.
- `page-demo`: `track-demo`, then the open card pages sideways to the next tracks and back before it's dismissed.

`docs/screenshots/` holds reference captures and `docs/videos/` reference recordings.

## How we keep runs down

Every run is a macOS job, which GitHub bills at 10x the Linux rate, and the build costs far more than the scenes (about 6–12 minutes, against 5–10 seconds per still). So `scripts/ci-screenshots.py` works hard not to start runs:

| Rule | What happens |
| --- | --- |
| Auto scenes (default) | Captures only the scenes touched by changes since the branch's last full run. `scripts/ci/screenshot-scenes.txt` maps files to scenes, and a file that isn't listed counts as every scene. If nothing visual changed, no run starts. |
| Recordings opt-in | `-demo` scenes (30–60 seconds each) only run when named with `--scenes`. |
| Reuse | If a successful run of the same commit, device and appearance already covered the scenes, it downloads those results instead of starting a run. |
| Coalesce | If a run for the branch is queued or running, it waits for it, then starts one follow-up run for anything pushed in the meantime. The workflow's `concurrency` group applies the same rule to runs started by hand. |
| Throttle | At most one new run per branch every 15 minutes and 10 per branch per 24 hours (`SCREENSHOTS_COOLDOWN_MIN`, `SCREENSHOTS_DAILY_MAX`). When throttled it exits with status **3**: keep working and fold the next changes into one later run. `--force` skips the throttle. |

When you add a view or move code between views, update `scripts/ci/screenshot-scenes.txt`. The first matching line wins.

## On a Mac

```sh
xcodegen generate
xcodebuild -scheme EveningsBroadcaster -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
scripts/simulator-screenshots.sh \
  build/DerivedData/Build/Products/Debug-iphonesimulator/Evenings.app screenshots
```

## How the workflow is put together

The workflow file is a thin wrapper. The actual steps (select Xcode, run XcodeGen, build, capture) live in `scripts/ci/simulator-screenshots-job.sh`, so they can change without touching `.github/workflows/`, which helps with tokens that lack the `workflow` scope. `scripts/ci/simulator-screenshots.yml` is the source copy of the workflow; copy it over `.github/workflows/` when it changes.

The job needs **Xcode 26**: HaishinKit 2.2+ uses an iOS 26 SDK API (`kVTCompressionPropertyKey_VariableBitRate`), and GitHub's `macos-15` image defaults to Xcode 16.4, which can't compile it. The job script selects the newest `/Applications/Xcode_26*.app` for that reason.
