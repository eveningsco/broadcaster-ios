# Evenings Broadcaster for iOS

The Evenings app for iPhone. We built it so a station can go live from wherever it is: plug in an audio interface or use the phone's own microphone, press **Go Live**, and the broadcast reaches your listeners on [evenings.fm](https://evenings.fm) like any other show.

With it, you can:

- **Go live** over RTMP from the built-in mic or a connected USB/Lightning interface, and keep broadcasting with the phone locked.
- **Record** a show offline and upload it to your library once you're back online.
- **Browse** your library and the Explore feed of live channels and published shows across Evenings.
- **Edit** your tracks: trim them, or change their tempo.

It's a native Swift and SwiftUI app, and it streams through [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift).

## Building

You'll need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app runs on iOS 16 and up.

```sh
xcodegen generate
open EveningsBroadcaster.xcodeproj
```

Swift Package Manager resolves dependencies on the first build. HaishinKit is pinned to an exact version in `project.yml`; to upgrade it, change `exactVersion` there and run `xcodegen generate` again. Xcode 26 is a hard requirement, because HaishinKit 2.2+ uses an iOS 26 SDK API.

Simulator builds work, but the simulator's microphone pipeline is unreliable, so test capture on a real device. We learned that one the hard way.

## How it works

- **Signing in.** The app calls `POST /v1/devices/connect` with the phone's vendor ID and keeps the session in the Keychain: a one-hour access token, a 28-day refresh token, and the station's stream key. Creating an account goes through the same `POST /auth/signup` the website uses, then connects the device with those credentials, so a new station ends up with the same session a sign-in produces.
- **Capture.** `AVAudioSession` runs in `.playAndRecord` at a preferred 48 kHz, with an `AVAudioEngine` input tap. A connected interface becomes the active input automatically, and the same tap drives the level meter.
- **Going live.** HaishinKit publishes AAC at 192 kbps over RTMP. That matches the Evenings desktop broadcaster's settings, so the media server treats a phone like any other encoder. The `audio` background mode keeps the broadcast going when the phone locks.
- **Recording.** Record mode writes the same 192 kbps AAC to an `.m4a` file on the phone, at up to 48 kHz, and uploads it to your library (`POST /v1/tracks`) when you stop. If the upload fails or you're offline, the file stays on the phone as a draft until it can go up.

### When the connection drops

A dropped connection ends the broadcast session on the server, which saves what it received as a recording. The app reconnects on its own with capped exponential backoff (1 second, then 2, 4 and 8, then every 10 seconds) until you're back on air or you end the broadcast. If the old connection is still half-open on the server, the new one takes over the stream instead of being turned away.

For now, each reconnect starts a new recording, so a show with network drops lands in your library as several tracks. That's not what anyone wants from a bad signal, so a server-side grace window that resumes the same recording after a short drop is on our list.

## Project layout

```
Sources/
  BroadcasterApp.swift         SwiftUI entry point
  AppModel.swift               Session state: sign-in and sign-up, token refresh,
                               Keychain persistence, library and Explore paging
  Config.swift                 API, web, RTMP and media endpoints; bitrate; brand colors
  API/
    EveningsAPI.swift          Evenings API client and response models
    Keychain.swift             Device session storage
  Broadcast/
    BroadcastController.swift  Capture → HaishinKit RTMP publish, level metering,
                               reconnect loop with backoff
    StreamAudioConformer.swift Converts capture to the 48 kHz shape the AAC encoder needs
    TrackPlayer.swift          Playback with lock-screen controls
    WaveformLoader.swift       Waveforms for the mini player
  Recording/
    RecordingController.swift  Offline recording to .m4a
    AACBufferWriter.swift      PCM → AAC file writer (handles inputs above 48 kHz)
    Faststart.swift            Moves the moov atom up front so the server can read duration
    UploadManager.swift        Uploads recordings; keeps failed ones as drafts
  UI/
    HomeView.swift             Library card over the broadcast stage, tabs, mini player
    BroadcastView.swift        The stage: Go Live and Record, timer, listener count, level ring
    LibraryView.swift          Your tracks and the ones you've saved
    ExploreView.swift          Live channels and published tracks across Evenings
    TrackDetailView.swift      Track detail card (cover, scrubber, share, edit)
    AudioEditView.swift        Trim and tempo editor
    TrimEditView.swift         Trim
    TempoEditView.swift        Tempo (varispeed)
    LoginView.swift            Sign-in
    SignUpView.swift           Account creation, with the website's rules
    AuthComponents.swift       Pieces shared by sign-in and sign-up
    AccountView.swift          Account sheet (station photo, name, sign out)
    Typography.swift           ABC Social with Dynamic Type
  Debug/
    ScreenshotMode.swift       Debug-only fixture scenes for screenshots
```

## Screenshots

You can see every screen without a Mac: a GitHub Actions workflow builds the app, runs it in a simulator, and captures each scene, including short recordings of the editor and track card in motion. [docs/screenshots.md](docs/screenshots.md) covers how to start a run, the scene list, and how we keep macOS build minutes down.

## TestFlight builds

`.github/workflows/testflight.yml` archives the app on a macOS runner and uploads it to TestFlight. It runs only when started by hand, and only from `main`: Actions → **TestFlight** → **Run workflow**, or `gh workflow run testflight.yml --ref main`. Build numbers come from the run number, so they always increase.

To set it up the first time:

1. In App Store Connect, go to Users and Access → Integrations → App Store Connect API and create a key with the **Admin** role, which cloud-managed signing needs.
2. Add `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the full contents of the downloaded `.p8` file) as secrets of the `testflight` environment, under Settings → Environments. `scripts/protect-branches.sh` restricts that environment to `main` and adds a required reviewer.
3. In TestFlight, add yourself to an internal testing group with automatic distribution turned on. New builds appear in the TestFlight app once Apple has processed them, usually 5–15 minutes after the run finishes.

## License

The source code is released under the [MIT License](LICENSE). The license doesn't cover the Evenings name, logo or app icon, and the bundled commercial fonts are used under their own licenses.

If the app doesn't build, or something sounds wrong on a real device, open an issue with your Xcode version and the audio interface you're using, and we'll take a look.
