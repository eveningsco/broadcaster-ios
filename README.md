# Evenings Broadcaster (iOS)

Native Swift iOS app for broadcasting live audio to the Evenings platform.
Log in or create a station, capture the active audio input (built-in mic or a
connected USB/Lightning interface), and either go live (AAC over RTMP to the
media server, with automatic reconnection and background streaming) or record
offline and upload to your library. The app also browses your library and the
platform's Explore feed, plays tracks, and trims or re-speeds them.

## Architecture

```
Sources/
  BroadcasterApp.swift        SwiftUI entry point
  AppModel.swift              Session state: login/sign-up, token refresh, Keychain
                              persistence, library and explore paging
  Config.swift                API, web, RTMP and media endpoints; bitrate; brand colors
  API/
    EveningsAPI.swift         Evenings API client (auth, devices, library, explore,
                              tracks, uploads) and response models
    Keychain.swift            Device session storage (kSecClassGenericPassword)
  Broadcast/
    BroadcastController.swift AVAudioEngine capture -> HaishinKit RTMP publish,
                              level metering, reconnect loop with backoff
    StreamAudioConformer.swift Converts capture to the 48 kHz shape the AAC encoder needs
    TrackPlayer.swift         AVPlayer playback with Now Playing / lock-screen controls
    WaveformLoader.swift      Coarse waveform for the mini player
  Recording/
    RecordingController.swift Offline recording to .m4a in Documents/recordings
    AACBufferWriter.swift     PCM -> AAC file writer (handles >48 kHz inputs)
    Faststart.swift           Moves the moov atom up front so the server can read duration
    UploadManager.swift       Uploads recordings (POST /v1/tracks); keeps failed ones as drafts
  UI/
    HomeView.swift            Library card over the broadcast stage, tabs, mini player
    BroadcastView.swift       The stage: Go Live / Record, timer, listener count, level ring
    LibraryView.swift         Your tracks and saved tracks
    ExploreView.swift         Live channels and published tracks across the platform
    TrackDetailView.swift     Track detail card (cover, scrubber, share, edit)
    AudioEditView.swift       Combined trim + tempo editor
    TrimEditView.swift        Trim editor
    TempoEditView.swift       Varispeed (tempo) editor
    LoginView.swift           Sign-in; pushes SignUpView
    SignUpView.swift          Account creation (same form + rules as the website's /signup)
    AuthComponents.swift      Header, field style, primary button shared by the two
    AccountView.swift         Account sheet (station photo, name, sign out)
    Typography.swift          ABC Social with Dynamic Type
  Debug/
    ScreenshotMode.swift      Debug-only fixture scenes for CI screenshots
```

- **Auth**: `POST /v1/devices/connect` with the phone's vendor ID; JWT (1h) +
  refresh token (28d) + stream key stored in the Keychain. Sign-up calls the
  website's `POST /auth/signup` (email, stationName, password) and then
  `/v1/devices/connect` with the same credentials, so a new account ends up
  with the same device session a login produces. The connect/refresh
  responses include `channelId` and `station {id, slug, name, image}` (added to
  the API server alongside this app; decoded optionally, and the account sheet
  falls back to the station on your own library tracks until it is deployed).
- **Capture**: `AVAudioSession` (.playAndRecord, 48 kHz preferred) +
  `AVAudioEngine` input tap. External interfaces show up as the active input
  route automatically. The same tap feeds the RMS level meter.
- **Encode/transport**: HaishinKit RTMPStream, AAC 192 kbps — matching the
  desktop broadcaster's FFmpeg settings, so the media server sees no difference.
- **Background**: `UIBackgroundModes: [audio]` keeps the stream alive when the
  phone locks.

## Reconnection

A dropped connection ends the server-side broadcast session, and the media
server saves what it received as a recording. The app reconnects on its own
with capped exponential backoff (1s → 10s), retrying until it gets back on
air or the broadcaster ends the broadcast.

- **Stale connections don't block reconnects.** If the old connection is
  still half-open on the server, a new publish with the same stream key takes
  over the stream instead of being rejected.
- **Each reconnect currently starts a new recording**, so a broadcast with
  network drops shows up as several tracks in the library. A server-side
  grace window that resumes the same recording after a brief drop is planned.

## Building

Requires Xcode 26+ (HaishinKit 2.2+ needs it) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open EveningsBroadcaster.xcodeproj
```

Dependencies resolve via Swift Package Manager on first build. HaishinKit is
pinned to an exact version in `project.yml`; to upgrade, change
`exactVersion` there and run `xcodegen generate`.
Simulator builds work but the simulator's mic pipeline is unreliable — test
capture on a real device.

## TestFlight builds

Nobody needs a Mac to try a branch on a phone either: the **TestFlight**
workflow (`.github/workflows/testflight.yml`, source copy in
`scripts/ci/testflight.yml`) archives the app on a macOS runner and uploads it
to App Store Connect. Any branch can be uploaded. It only runs when started by
hand:

```sh
GH_TOKEN=... scripts/testflight.sh                 # current branch
GH_TOKEN=... scripts/testflight.sh thread/abc123   # a specific branch
# or: Actions tab → TestFlight → Run workflow → pick the branch
```

The run takes ~15 min, Apple processes the build for another ~5–15 min, then
the TestFlight app on the phone shows the new build (Evenings → **Previous
Builds** lists all of them; the build number is `100 + run number`, and the
run's summary says which branch/sha it came from). Build numbers always
increase, so a `main` build uploaded after a thread build is "newer" even if
its code is older — check the summary, not the number.

One-time setup:

1. App Store Connect → Users and Access → Integrations → App Store Connect API:
   create a key with the **Admin** role (needed for cloud-managed signing).
   Note the Key ID and Issuer ID and download the `.p8` (one download only).
2. GitHub → Settings → Environments → **New environment** `testflight`. Add
   three environment secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8`
   (the full contents of the `.p8`). Don't restrict deployment branches to
   `main`, or thread branches can't be uploaded; a required reviewer is fine
   (approving is one tap in the GitHub app).
3. In TestFlight, add yourself to an internal testing group with automatic
   distribution on; new builds then show up in the TestFlight app once
   processed.

## Screenshots

Nobody needs a Mac to see the UI: the **Simulator Screenshots** GitHub Actions
workflow builds the app on a macOS runner, boots an iPhone simulator and
captures every screen to a PNG artifact.

```sh
# From any machine with python3 and a GitHub token with `repo` scope:
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch            # scenes your changes touch
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch --dry-run  # what it would do, without doing it
GH_TOKEN=... scripts/ci-screenshots.py --scenes "login stage"     # exactly these scenes
# → screenshots/<scene>.png
```

**How often runs happen.** Every run is a macOS job (10x billing) and the
build costs far more than the scenes (~6–12 min vs ~5–10 s per still), so
`scripts/ci-screenshots.py` avoids starting runs:

| Rule | What happens |
| --- | --- |
| Auto scenes (default) | Captures only the scenes touched by changes since the branch's last full run. Which files touch which scenes is listed in `scripts/ci/screenshot-scenes.txt`. A file that isn't listed counts as every scene. If nothing visual changed, it starts no run. |
| Recordings opt-in | `-demo` scenes (~30–60 s each) only run when named with `--scenes`. |
| Reuse | If a successful run of the same commit, device and appearance already covered the scenes, it downloads that run's results instead of starting a new run. |
| Coalesce | If a run for the branch is queued or running, it waits for that run. It then starts one follow-up run for anything pushed in the meantime. The workflow's `concurrency` group enforces the same rule for runs started by hand. |
| Throttle | At most 1 new run per branch every 15 min and 10 per branch per 24 h (`SCREENSHOTS_COOLDOWN_MIN`, `SCREENSHOTS_DAILY_MAX`). When throttled it exits with status **3**: keep working and fold the next changes into one later run. `--force` skips the throttle. |

When you add a view or move code between views, update
`scripts/ci/screenshot-scenes.txt`. The first matching line wins.

> **Setup (once):** GitHub only knows about a `workflow_dispatch`-only
> workflow once its file exists on the **default branch** (`main`) — until
> then, dispatching by file name returns `404 Not Found` from the API and the
> workflow is missing from the Actions tab. Land
> `.github/workflows/simulator-screenshots.yml` on `main` once; after that
> `--ref` can point at any branch that has the file.

The workflow file is a thin wrapper; the actual steps (select Xcode, XcodeGen,
`xcodebuild`, capture) live in `scripts/ci/simulator-screenshots-job.sh` so
they can be changed without touching `.github/workflows/` (useful for tokens
without the `workflow` scope). `scripts/ci/simulator-screenshots.yml` is
the source copy of the workflow — `cp` it over `.github/workflows/` when it
changes. **Xcode 26 is required**: HaishinKit 2.2+ uses
`kVTCompressionPropertyKey_VariableBitRate` (iOS 26 SDK), so the job script
`xcode-select`s the newest `/Applications/Xcode_26*.app` — GitHub's `macos-15`
image defaults to Xcode 16.4, which fails to compile HaishinKit.

Or trigger it by hand (Actions → Simulator Screenshots → Run workflow) and
download the `simulator-screenshots` artifact. A cold run takes ~8–12 minutes
(SPM resolve + build dominate); macOS minutes bill at 10x Linux, so the
workflow is manual-only rather than running on every push.

The app supports a debug-only **screenshot mode** that makes this possible:
launching with `-screenshot <scene>` renders that scene from fixture data
(`Sources/Debug/ScreenshotMode.swift`) with no account, network, Keychain or
microphone involved. Scenes: `login`, `signup` (account creation), `library`,
`explore`, `account` (the station/sign-out sheet from the header gear),
`edit` (the trim + tempo audio editor over the library), `track` (the track
detail card — cover, scrubber, share and Edit — floating over the library), `stage`
(idle, "Go Live") and `live` (on air, timer). Scenes ending in `-demo`
animate instead of posing — `edit-demo` has the editor trim, audition and
re-speed a track by itself with a ghost fingertip; `track-demo` taps a
track's cover so it flies out of the row into the detail card over the
frosted library, dismisses it and repeats (at half speed, so the ~15 fps
CI simulator catches the motion) — and the capture script
*records* them (`simctl io recordVideo`, ~24 s) into `<scene>.mov` plus an
animated `<scene>.png`, so `--scenes edit-demo` yields a short video of the
editor in motion. On a Mac:

```sh
xcodegen generate
xcodebuild -scheme EveningsBroadcaster -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
scripts/simulator-screenshots.sh \
  build/DerivedData/Build/Products/Debug-iphonesimulator/Evenings.app screenshots
```

The mode is compiled out of Release builds. `docs/screenshots/` holds
reference captures and `docs/videos/` reference recordings
(`edit-demo.{mp4,gif}`: the combined audio editor in motion, CI run
37180113601, 2026-10-04).

## Not yet implemented

- Live metadata editing (`PUT /v1/streams/:slug/live`)
- Streaming a local file (document picker)
- App-audio capture (ReplayKit broadcast upload extension)
- RTMPS: needs TLS support on the media server first

## License

Licensed under the [MIT License](LICENSE). The license covers the source code
only: it does not grant rights to the Evenings name, logo or app icon, and the
bundled commercial fonts are used under their own separate licenses.
