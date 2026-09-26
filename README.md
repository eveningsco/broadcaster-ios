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

## TestFlight builds

`.github/workflows/testflight.yml` archives the app on a macOS runner and
uploads it to TestFlight on every push to `main` or `claude/**` (and on demand
from the Actions tab). Build numbers come from the run number, so they always
increase. One-time setup:

1. App Store Connect → Users and Access → Integrations → App Store Connect API:
   create a key with the **Admin** role (needed for cloud-managed signing).
2. Add repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` (the full
   contents of the downloaded `.p8`).
3. In TestFlight, add yourself to an internal testing group with automatic
   distribution on; new builds then show up in the TestFlight app once
   processed (~5–15 min after the run finishes).

## Not yet implemented (post-MVP)

- Library screen (`GET /v1/library`) and post-broadcast "recording saved" flow
- Live metadata editing (`PUT /v1/streams/:slug/live`)
- Local file streaming (document picker)
- App-audio capture (ReplayKit broadcast upload extension)
- RTMPS (needs server-side TLS termination first)
