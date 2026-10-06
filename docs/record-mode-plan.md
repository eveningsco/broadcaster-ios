# Record Mode — Plan

A second mode next to Go Live: **Record** captures audio offline (no network
needed), then uploads the file to the station's library when done. The
recording ends up in the same library list as broadcast recordings.

## Why this is cheap: what already exists

What the Evenings API already provides:

- **Upload endpoint**: `POST /v1/tracks` accepts a multipart upload with the
  file in the **`audio`** field, stores it, and works with the device session
  the app already holds.
- **Duration is computed server-side** from the uploaded file, so uploaded
  tracks appear in the library (which hides tracks without a duration) as soon
  as the upload finishes. No callback needed.
- **Title = uploaded filename**. `PATCH /v1/tracks/:id`
  exists for renaming, so the app uploads with a real filename then PATCHes a
  clean display title.
- The app already has: the capture pipeline (AVAudioEngine tap, already
  metering), background-audio mode, Keychain session with token refresh, and
  the library screen with post-action refresh polling.

## Format decision

**AAC in .m4a (MPEG-4), 48 kHz, 192 kbps, `AVAudioFile` writing from the
existing tap.** iOS has no MP3 encoder (LAME would add licensing/build
complexity); AAC-m4a is hardware-encoded, plays everywhere the platform plays
audio (AVPlayer, HTML5 `<audio>`), and the server reads its duration fine. This
matches the broadcast encode settings (AAC 192k/48k) rather than the desktop
app's local MP3 256k.

## UX

**Mode switch on the stage** (visible when the sheet is pulled down): a small
`Live | Record` segmented control above the action button.

Record mode states:

1. **Idle** — level meter live (mic monitoring already runs on the stage),
   button reads **Record** (red circle).
2. **Recording** — elapsed timer (reuse the broadcast timer UI), level meter,
   button reads **Stop**. Locking the phone keeps recording (background audio
   mode, same as broadcasting). Status badge shows "RECORDING" instead of
   "LIVE"; no listener count.
3. **Saving** — on Stop: upload starts with a determinate progress bar
   ("Saving to your library…"). On success: sheet springs up and the library
   polls until the new track appears (reuse `refreshLibraryAfterBroadcast`,
   generalized).
4. **Upload failed / offline** — the file is already safe on disk. Show
   "Saved on this phone — will upload when you're back online" with a Retry
   button. The library tab shows a **"On this phone"** section at the top
   listing pending drafts (playable locally, retry/delete).

Rules:
- Mode switch disabled while live or recording.
- Going live is disabled while recording (one capture consumer in v1).
- Default title: `Recording — Jul 4, 3:42 PM` (uploaded as
  `Recording — Jul 4, 3.42 PM.m4a`, then PATCHed to the clean title).

## Architecture

```
BroadcastController (owns AVAudioEngine + tap)
  └─ tap callback fans out to sinks:
       • RMS meter (existing)
       • RTMPStream.append (existing, when live)
       • RecordingSink (new): AVAudioFile writer
```

- **Refactor**: the tap closure in `BroadcastController.startCapture()` gets a
  small sink list instead of hard-coding meter+stream. This is ~20 lines and
  also unlocks "record while live" later.
- **New `RecordingController`** (`@MainActor`, `ObservableObject`):
  - `state: idle | recording(since: Date) | uploading(progress: Double) | failed(draft: Draft)`
  - `start()` — ensure audio session + engine running (reuse monitoring path),
    create `AVAudioFile` (AAC settings) in `Documents/recordings/`, register
    sink.
  - `stop()` — close file, hand off to the uploader.
  - Handles `AVAudioSession.interruptionNotification` (phone call: pause
    writing, resume on `.ended` — the file just keeps appending).
- **New `TrackUploader`**: multipart `POST /v1/tracks` via
  `URLSession.uploadTask` with a delegate for progress; on 200, `PATCH` the
  title, delete the local file, trigger library refresh. On failure, keep the
  file as a draft.
- **Drafts**: the files themselves are the store (`Documents/recordings/*.m4a`,
  filename encodes the timestamp). No database — list the directory. A draft
  row offers play (local URL via existing `TrackPlayer`), retry upload, delete.

## Edge cases to handle

- **Route changes mid-recording** (unplug USB interface): the tap format was
  fixed at install; AVAudioEngine posts a configuration-change notification —
  restart the tap with the new format and keep writing (AVAudioFile converts).
- **Storage**: 192 kbps ≈ 84 MB/hour — fine, but check free space at start and
  warn under ~500 MB.
- **App killed mid-recording**: the partial .m4a is on disk; `AVAudioFile`
  output is playable up to the last written frame in practice. It shows up as
  a draft on next launch. (Good enough for v1; note in the draft row that it
  may be truncated.)
- **Token expiry during a long offline stretch**: refresh token lasts 28 days;
  uploader calls `ensureFreshSession()` before each attempt.
- **Very long uploads**: v1 uploads in-foreground (screen can lock — audio
  session keeps us alive only while *capturing*, so uploads should happen with
  the app active). v2 moves to a background `URLSession` so uploads survive
  app suspension.

## Phasing

1. **v1** — sink refactor, RecordingController, record UI states, m4a writer,
   foreground upload + PATCH title, drafts section with retry/delete, library
   refresh on success. Zero backend changes.
2. **v2** — background URLSession uploads, upload queue that auto-retries on
   connectivity return (NWPathMonitor), pause/resume while recording.
3. **Later** — record-while-live (the sink architecture already allows it),
   waveform scrubber preview before upload, trim, local-only recordings.

## Open questions

- Should recordings auto-upload, or should the user confirm/see the draft
  first? (Plan assumes auto-upload with drafts as the failure path — matches
  "recordings save automatically" for broadcasts.)
- Default title format — station name in it? ("Osebo — Recording Jul 4"?)
