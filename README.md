# Evenings Broadcaster (iOS)

Native Swift iOS app for broadcasting live audio to the Evenings platform.
MVP scope: log in, capture the active audio input (built-in mic or a connected
USB/Lightning interface), and publish AAC over RTMP to the media server, with
automatic reconnection and background streaming.

## Architecture

```
Sources/
  BroadcasterApp.swift      SwiftUI entry point
  AppModel.swift            Session state: login, token refresh, Keychain persistence
  Config.swift              API + RTMP endpoints, bitrate
  API/
    EveningsAPI.swift       /v1/devices/connect, /refresh, /v1/streams/:id/status
    Keychain.swift          Credentials storage (kSecClassGenericPassword)
  Broadcast/
    BroadcastController.swift  AVAudioEngine capture -> HaishinKit RTMP publish,
                               level metering, reconnect loop with backoff
  UI/
    LoginView.swift
    BroadcastView.swift     Go Live / End, elapsed time, listener count, level meter
```

- **Auth**: `POST /v1/devices/connect` with the phone's vendor ID; JWT (1h) +
  refresh token (28d) + stream key stored in the Keychain. The connect/refresh
  responses include `channelId` and `station {id, slug, name}` (added to the API
  server alongside this app).
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

## Screenshots

Nobody needs a Mac to see the UI: the **Simulator Screenshots** GitHub Actions
workflow builds the app on a macOS runner, boots an iPhone simulator and
captures every screen to a PNG artifact.

```sh
# From any machine with python3 and a GitHub token with `repo` scope:
GH_TOKEN=... scripts/ci-screenshots.py --ref my-branch --appearance both
# → screenshots/{login,library,explore,stage,live}-{light,dark}.png
```

> **Setup (once):** the workflow definition lives at
> `scripts/ci/simulator-screenshots.yml` until a human moves it to
> `.github/workflows/` — pushing workflow files needs a token with the
> `workflow` scope, which the forum agent's token lacks.

Or trigger it by hand (Actions → Simulator Screenshots → Run workflow) and
download the `simulator-screenshots` artifact. A cold run takes ~8–12 minutes
(SPM resolve + build dominate); macOS minutes bill at 10x Linux, so the
workflow is manual-only rather than running on every push.

The app supports a debug-only **screenshot mode** that makes this possible:
launching with `-screenshot <scene>` renders that scene from fixture data
(`Sources/Debug/ScreenshotMode.swift`) with no account, network, Keychain or
microphone involved. Scenes: `login`, `library`, `explore`, `stage` (idle,
"Go Live") and `live` (on air, timer, listeners). On a Mac:

```sh
xcodegen generate
xcodebuild -scheme EveningsBroadcaster -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
scripts/simulator-screenshots.sh \
  build/DerivedData/Build/Products/Debug-iphonesimulator/Evenings.app screenshots
```

The mode is compiled out of Release builds. `docs/screenshots/` holds
reference captures.

## Not yet implemented (post-MVP)

- Library screen (`GET /v1/library`) and post-broadcast "recording saved" flow
- Live metadata editing (`PUT /v1/streams/:slug/live`)
- Local file streaming (document picker)
- App-audio capture (ReplayKit broadcast upload extension)
- RTMPS (needs server-side TLS termination first)
