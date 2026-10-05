# Evenings Broadcaster (iOS)

Native Swift iOS app for broadcasting live audio to the Evenings platform.
MVP scope: log in, capture the active audio input (built-in mic or a connected
USB/Lightning interface), and publish AAC over RTMP to the media server, with
automatic reconnection and background streaming.

## Architecture

```
Sources/
  BroadcasterApp.swift      SwiftUI entry point
  AppModel.swift            Session state: login/sign-up, token refresh, Keychain persistence
  Config.swift              API + RTMP endpoints, bitrate
  API/
    EveningsAPI.swift       /auth/signup, /v1/devices/connect, /refresh, library/explore
    Keychain.swift          Credentials storage (kSecClassGenericPassword)
  Broadcast/
    BroadcastController.swift  AVAudioEngine capture -> HaishinKit RTMP publish,
                               level metering, reconnect loop with backoff
  UI/
    LoginView.swift         Sign-in; pushes SignUpView
    SignUpView.swift        Account creation (same form + rules as the website's /signup)
    AuthComponents.swift    Header, field style, primary button shared by the two
    AccountView.swift       Account sheet (station photo, name, sign out) from the header gear
    BroadcastView.swift     Go Live / End, elapsed time, listener count, level meter
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

## Reconnection (important)

The media server (`simple-media-server`) currently has **zero reconnect
tolerance**:

- Any TCP drop immediately ends the server-side session, finalizes the
  recording as a Track, and may flip the channel to dead-air. Each
  drop/reconnect cycle produces a **separate recording** in the library.
- A half-open dead socket can cause fast re-publishes to be rejected with
  "Stream already publishing" until the server reaps the stale session (its
  60s ping timeout tries to keep connections alive rather than kill them).

The app therefore retries with capped exponential backoff (1s → 10s)
indefinitely until the key frees up. Planned server-side fixes that would make
mobile broadcasting much better:

1. **Publish takeover**: a new publish with a valid key kicks a stale session
   instead of being rejected.
2. **Reconnect grace window**: delay finalization ~30s after a dirty disconnect
   and resume the same recording session if the same key re-publishes.

Also note the media server is plain RTMP on 1935 (no TLS termination in the
server itself).

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open EveningsBroadcaster.xcodeproj
```

Dependencies (HaishinKit) resolve via Swift Package Manager on first build.
Simulator builds work but the simulator's mic pipeline is unreliable — test
capture on a real device.

## TestFlight builds

`.github/workflows/testflight.yml` archives the app on a macOS runner and
uploads it to TestFlight. It only runs when started by hand: Actions tab →
**TestFlight** → **Run workflow** (pick the branch), or
`gh workflow run testflight.yml --ref <branch>`. Build numbers come from the
run number, so they always increase. One-time setup:

1. App Store Connect → Users and Access → Integrations → App Store Connect API:
   create a key with the **Admin** role (needed for cloud-managed signing).
2. Add repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` (the full
   contents of the downloaded `.p8`).
3. In TestFlight, add yourself to an internal testing group with automatic
   distribution on; new builds then show up in the TestFlight app once
   processed (~5–15 min after the run finishes).

## Screenshots

Nobody needs a Mac to see the UI: the **Simulator Screenshots** GitHub Actions
workflow builds the app on a macOS runner, boots an iPhone simulator and
captures every screen to a PNG artifact.

```sh
# From any machine with python3 and a GitHub token with `repo` scope:
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch
# → screenshots/{login,signup,library,explore,account,edit,stage,live}.png
```

> **Setup (once):** GitHub only knows about a `workflow_dispatch`-only
> workflow once its file exists on the **default branch** (`main`) — until
> then, dispatching by file name returns `404 Not Found` from the API and the
> workflow is missing from the Actions tab. Land
> `.github/workflows/simulator-screenshots.yml` on `main` once; after that
> `--ref` can point at any branch that has the file.

The workflow file is a thin wrapper; the actual steps (select Xcode, XcodeGen,
`xcodebuild`, capture) live in `scripts/ci/simulator-screenshots-job.sh` so
they can be changed without touching `.github/workflows/` (the forum agent's
token lacks the `workflow` scope). `scripts/ci/simulator-screenshots.yml` is
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

## Not yet implemented (post-MVP)

- Library screen (`GET /v1/library`) and post-broadcast "recording saved" flow
- Live metadata editing (`PUT /v1/streams/:slug/live`)
- Local file streaming (document picker)
- App-audio capture (ReplayKit broadcast upload extension)
- RTMPS (needs server-side TLS termination first)

## License

Licensed under the [MIT License](LICENSE). The license covers the source code
only: it does not grant rights to the Evenings name, logo or app icon, and the
bundled commercial fonts are used under their own separate licenses.
