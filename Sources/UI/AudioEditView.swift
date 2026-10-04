import AVFoundation
import SwiftUI
import UIKit

/// Tap for transport and a confirmation buzz when the edited version lands.
/// (The strip and the wheel bring their own tick haptics.)
private enum AudioEditHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let confirm = UINotificationFeedbackGenerator()
}

/// The library's one audio editor: trim and tempo on a single page, over a
/// single preview. The strip's in/out handles set a looping audition region
/// and the speed wheel bends its rate, so what loops under your finger is
/// exactly what gets saved — the selection, at that speed. Saving renders a
/// new track next to the untouched original.
///
/// Replaces the separate Trim and Adjust Tempo sheets (2026-10-04); the
/// pieces they were built from — `TempoPreview`, `TrimStrip`, `SpeedWheel`,
/// the renderers — are reused as-is.
struct AudioEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: LibraryTrack

    @StateObject private var preview = TempoPreview()
    @StateObject private var waveform = IncrementalWaveform()
    /// Selection as fractions of the track.
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var saveState: SaveState = .idle
    /// Screenshot mode's `edit-demo` scene: the page drives itself (see
    /// `runDemo`). Inert otherwise.
    @State private var demo = Demo.Values()

    private let api = EveningsAPI()

    enum SaveState: Equatable {
        case idle
        case downloading(Double)
        case rendering(Double)
        case uploading(Double)
        case failed(String)
    }

    private var isSaving: Bool {
        switch saveState {
        case .downloading, .rendering, .uploading: return true
        case .idle, .failed: return false
        }
    }

    /// Screenshot mode renders the page from fixtures: the preview never
    /// loads (no network), so readiness, duration, levels and the playhead
    /// come from `ScreenshotFixtures` instead.
    private var isFixture: Bool { ScreenshotMode.isActive }
    private var isDemo: Bool { ScreenshotMode.scene?.animatesEditor == true }
    private var isReady: Bool { preview.isReady || isFixture }
    private var duration: TimeInterval {
        isFixture ? TimeInterval(track.duration ?? 0) : preview.duration
    }
    private var progress: Double {
        if isDemo { return demo.progress }
        return isFixture ? ScreenshotFixtures.editPlayhead : preview.progress
    }
    private var isPlaying: Bool { isDemo ? demo.isPlaying : preview.isPlaying }
    private var levels: [Float]? { waveform.levels ?? (isFixture ? ScreenshotFixtures.editWaveform : nil) }

    private var percent: Int {
        Int((preview.rate * 100).rounded())
    }

    /// Either edit alone is enough to save; neither means nothing to render.
    private var hasTrim: Bool {
        trimStart > 0.0005 || trimEnd < 0.9995
    }
    private var hasTempo: Bool { percent != 100 }
    private var hasEdits: Bool { hasTrim || hasTempo }

    private var minGapFraction: Double {
        duration > 0 ? min(5 / duration, 1) : 0.01
    }

    private var selectedDuration: TimeInterval {
        max(0, (trimEnd - trimStart) * duration)
    }

    /// Runtime of the saved file: the selection, resampled by the rate.
    private var outputDuration: TimeInterval {
        selectedDuration / preview.rate
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    readouts

                    Group {
                        if isReady {
                            TrimStrip(
                                start: $trimStart,
                                end: $trimEnd,
                                progress: progress,
                                levels: levels,
                                minGap: minGapFraction,
                                onScrubBegin: { preview.beginScrub() },
                                onScrubMove: { preview.scrubTo(fraction: $0) },
                                onScrub: { preview.endScrub(at: $0) },
                                onHandleMoved: { commitSelection() }
                            )
                        } else {
                            ProgressView("Loading audio…")
                        }
                    }
                    .frame(height: 132)
                    .overlay {
                        if case .strip(let fraction) = demo.finger {
                            GeometryReader { geometry in
                                Demo.Fingertip()
                                    .position(x: fraction * geometry.size.width, y: geometry.size.height / 2)
                            }
                        }
                    }
                }

                transport

                VStack(spacing: 10) {
                    SpeedWheel(value: $preview.rate)
                        .overlay {
                            if case .wheel(let offset) = demo.finger {
                                GeometryReader { geometry in
                                    Demo.Fingertip()
                                        .position(x: geometry.size.width / 2 + offset, y: geometry.size.height / 2)
                                }
                            }
                        }
                    // Varispeed changes the runtime; show where the
                    // selection lands. Blank (not absent) at 100% so the
                    // layout doesn't jump when the wheel leaves the detent.
                    Text(hasTempo
                         ? "\(Self.format(selectedDuration)) → \(Self.format(outputDuration)) at \(percent)%"
                         : " ")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                saveArea
            }
            .padding(24)
            .navigationTitle("Edit Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .task {
                if isDemo {
                    await runDemo()
                    return
                }
                if isFixture {
                    trimStart = ScreenshotFixtures.editSelection.lowerBound
                    trimEnd = ScreenshotFixtures.editSelection.upperBound
                    preview.rate = ScreenshotFixtures.editRate
                    return
                }
                // The mini player and the preview can't share the output.
                model.player.pause()
                guard let url = track.audioURL else { return }
                await preview.load(url: url, fallbackDuration: TimeInterval(track.duration ?? 0))
                preview.setLoop(startFraction: trimStart, endFraction: trimEnd)
                // Levels decode off the preview's own growing download —
                // no second fetch — and fill in left to right.
                if let fileURL = preview.sourceFileURL {
                    waveform.begin(
                        fileURL: fileURL,
                        duration: TimeInterval(track.duration ?? 0),
                        isComplete: { preview.isDownloadComplete }
                    )
                }
            }
            .onDisappear {
                preview.teardown()
                waveform.teardown()
            }
        }
    }

    /// In time, selected length, out time as one small line above the
    /// strip — numbers only, no labels. Left/right placement already says
    /// which is in and which is out; the middle one is the selection.
    private var readouts: some View {
        HStack(spacing: 0) {
            readout(trimStart * duration)
            Spacer(minLength: 8)
            readout(selectedDuration)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            readout(trimEnd * duration)
        }
        .font(.social(.footnote))
        .monospacedDigit()
        .lineLimit(1)
        .opacity(isReady ? 1 : 0)
    }

    private func readout(_ time: TimeInterval) -> some View {
        // Never wrap: three h:mm:ss values on an hour-long set need the
        // whole row, and a broken "16:05" is unreadable.
        Text(Self.format(time)).fixedSize()
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                AudioEditHaptics.tap.impactOccurred()
                preview.seek(toFraction: trimStart)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .frame(width: 64, height: 48)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                AudioEditHaptics.tap.impactOccurred()
                preview.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 96, height: 48)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .overlay {
                if demo.finger == .play {
                    Demo.Fingertip()
                }
            }
        }
        .disabled(!isReady)
    }

    private var saveTitle: String {
        switch (hasTrim, hasTempo) {
        case (true, true): return "Save Trimmed Version at \(percent)%"
        case (true, false): return "Save Trimmed Version"
        case (false, true): return "Save New Version at \(percent)%"
        case (false, false): return "Save New Version"
        }
    }

    @ViewBuilder
    private var saveArea: some View {
        VStack(spacing: 12) {
            switch saveState {
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading original…")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                }
            case .rendering(let progress):
                ProgressView(value: progress) {
                    Text(hasTempo ? "Rendering at \(percent)%…" : "Trimming…")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                }
            case .uploading(let progress):
                ProgressView(value: progress) {
                    Text("Uploading new version…")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.social(.footnote))
                    .foregroundStyle(Color.eveningsRed)
            case .idle:
                EmptyView()
            }

            Button(action: save) {
                Text(saveTitle)
                    .font(.social(.body, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.eveningsRed)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isReady || !hasEdits || isSaving)
            .opacity(!isReady || !hasEdits || isSaving ? 0.4 : 1)
        }
    }

    private func commitSelection() {
        preview.setLoop(startFraction: trimStart, endFraction: trimEnd)
    }

    /// Downloads the original (unless the preview already streamed all of
    /// it), renders the selection at the chosen rate in one offline pass,
    /// and uploads the result as a fresh track — nothing is overwritten.
    private func save() {
        guard let remote = track.audioURL else { return }
        guard let token = model.credentials?.accessToken else {
            saveState = .failed("Not signed in.")
            return
        }
        preview.pause()
        let startFraction = trimStart
        let endFraction = trimEnd
        let rate = preview.rate
        let resamples = hasTempo
        saveState = .downloading(0)
        Task {
            // The whole pipeline can run for minutes on a long set; if the
            // screen locks the app suspends and every socket dies. Keep the
            // screen awake, and buy grace time if the user briefly leaves.
            UIApplication.shared.isIdleTimerDisabled = true
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "audio-edit-save")
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            var phase = "download the original"
            do {
                let source: URL
                var ownsSource = false
                if remote.isFileURL {
                    source = remote
                } else if let finished = preview.completedFileURL {
                    // The preview's stream already pulled the whole file;
                    // don't download it twice. The sheet (and the temp
                    // file) outlive the save, which blocks dismissal.
                    source = finished
                } else {
                    source = try await TempoDownloader.download(from: remote) { progress in
                        Task { @MainActor in
                            if case .downloading = saveState {
                                saveState = .downloading(progress)
                            }
                        }
                    }
                    ownsSource = true
                }
                defer {
                    if ownsSource {
                        try? FileManager.default.removeItem(at: source)
                    }
                }
                phase = "render the new version"
                saveState = .rendering(0)
                let onRenderProgress: @Sendable (Double) -> Void = { progress in
                    Task { @MainActor in
                        if case .rendering = saveState {
                            saveState = .rendering(progress)
                        }
                    }
                }
                // At 100% there's nothing to resample: a straight frame copy
                // of the selection is both faster and bit-exact.
                let rendered: URL
                if resamples {
                    rendered = try await TempoRenderer.render(
                        source: source,
                        rate: rate,
                        startFraction: startFraction,
                        endFraction: endFraction,
                        onProgress: onRenderProgress
                    )
                } else {
                    rendered = try await TrimRenderer.render(
                        source: source,
                        startFraction: startFraction,
                        endFraction: endFraction,
                        onProgress: onRenderProgress
                    )
                }
                defer { try? FileManager.default.removeItem(at: rendered) }
                // Moov-to-front like every other upload, so web playback
                // starts immediately.
                let streamable = (try? await Faststart.makeStreamable(rendered)) ?? rendered
                defer {
                    if streamable != rendered {
                        try? FileManager.default.removeItem(at: streamable)
                    }
                }
                phase = "upload the new version"
                saveState = .uploading(0)
                let uploaded = try await api.uploadTrack(
                    fileURL: streamable,
                    filename: "edit-\(track.id).m4a",
                    accessToken: token
                ) { progress in
                    Task { @MainActor in
                        if case .uploading = saveState {
                            saveState = .uploading(progress)
                        }
                    }
                }
                let title = Self.title(
                    for: track,
                    trimmed: startFraction > 0.0005 || endFraction < 0.9995,
                    percent: resamples ? percent : nil
                )
                if track.owner != true {
                    // Someone else's track: stamp provenance in the
                    // description alongside the remix title.
                    try? await api.updateTrack(
                        id: uploaded.id,
                        title: title,
                        description: Self.remixCredit(for: track),
                        accessToken: token
                    )
                } else {
                    try? await api.updateTrackTitle(id: uploaded.id, title: title, accessToken: token)
                }
                await model.loadLibrary()
                AudioEditHaptics.confirm.notificationOccurred(.success)
                dismiss()
            } catch {
                saveState = .failed("Couldn't \(phase): \(error.localizedDescription)")
                AudioEditHaptics.confirm.notificationOccurred(.error)
            }
        }
    }

    // MARK: - Screenshot demo

    /// The `edit-demo` screenshot scene: ~15 s of the page using itself, for
    /// a simulator recording (`scripts/simulator-screenshots.sh` records
    /// scenes ending in `-demo`). A ghost fingertip marks each "touch". The
    /// values are tweened by hand at ~60 Hz rather than with `withAnimation`
    /// because the wheel is a `Canvas` and wouldn't interpolate. The
    /// audition is mimed: a 2 h fixture track's playhead would not visibly
    /// move at real speed, so it crosses the selection in a few seconds.
    private enum Demo {
        struct Values {
            var progress: Double = 0
            var isPlaying = false
            var finger: Finger?
        }

        enum Finger: Equatable {
            /// Over the trim strip, at a fraction of its width.
            case strip(Double)
            /// Over the speed wheel, offset in points from its centre.
            case wheel(CGFloat)
            case play
        }

        /// Translucent fingertip, roughly a thumb's contact patch.
        struct Fingertip: View {
            var body: some View {
                Circle()
                    .fill(Color.white.opacity(0.28))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .allowsHitTesting(false)
            }
        }
    }

    @MainActor
    private func runDemo() async {
        let target = ScreenshotFixtures.editSelection
        let targetRate = ScreenshotFixtures.editRate
        trimStart = 0
        trimEnd = 1
        preview.rate = 1
        demo.progress = 0

        // Let the sheet finish presenting.
        await pause(1.4)

        // Drag the in handle.
        touch(.strip(0))
        await pause(0.35)
        await tween(1.2) { t in
            trimStart = target.lowerBound * t
            demo.finger = .strip(trimStart)
        }
        await pause(0.25)
        touch(nil)
        await pause(0.5)

        // Drag the out handle.
        touch(.strip(1))
        await pause(0.35)
        await tween(1.2) { t in
            trimEnd = 1 - (1 - target.upperBound) * t
            demo.finger = .strip(trimEnd)
        }
        await pause(0.25)
        touch(nil)
        await pause(0.6)

        // Play: the playhead loops the selection until the end.
        touch(.play)
        await pause(0.3)
        demo.isPlaying = true
        demo.progress = trimStart
        let playhead = Task { @MainActor in
            let secondsPerPass = 4.5
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                let now = Date()
                let span = max(trimEnd - trimStart, 0.001)
                var next = demo.progress + now.timeIntervalSince(last) / secondsPerPass * span
                if next > trimEnd { next = trimStart + (next - trimEnd) }
                demo.progress = next
                last = now
            }
        }
        defer { playhead.cancel() }
        await pause(0.25)
        touch(nil)
        await pause(1.6)

        // Spin the wheel down to the fixture rate. Dragging the strip right
        // lowers the value (SpeedWheel.drag), 7 pt per percent.
        touch(.wheel(0))
        await pause(0.35)
        await tween(1.5) { t in
            preview.rate = 1 - (1 - targetRate) * t
            demo.finger = .wheel(CGFloat((1 - preview.rate) * 100 * 7))
        }
        preview.rate = targetRate
        await pause(0.3)
        touch(nil)

        // Hold on the finished edit, still looping, then rest on pause.
        await pause(3.5)
        touch(.play)
        await pause(0.3)
        demo.isPlaying = false
        playhead.cancel()
        await pause(0.25)
        touch(nil)
    }

    private func touch(_ finger: Demo.Finger?) {
        withAnimation(.easeOut(duration: 0.18)) {
            demo.finger = finger
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Calls `apply` with an eased 0→1 progress at roughly 60 Hz.
    @MainActor
    private func tween(_ duration: TimeInterval, _ apply: (Double) -> Void) async {
        let started = Date()
        while true {
            let linear = min(Date().timeIntervalSince(started) / duration, 1)
            let eased = linear < 0.5
                ? 2 * linear * linear
                : 1 - pow(-2 * linear + 2, 2) / 2
            apply(eased)
            if linear >= 1 { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Title for the saved version. Own tracks get the edit spelled out —
    /// `(trimmed)`, `(92%)`, `(trimmed, 92%)`; another station's track
    /// becomes `(remix)` / `(remix 92%)`, the same names the separate
    /// editors produced.
    static func title(for track: LibraryTrack, trimmed: Bool, percent: Int?) -> String {
        let base = track.title ?? "Untitled"
        if track.owner != true {
            if let percent {
                return "\(base) (remix \(percent)%)"
            }
            return "\(base) (remix)"
        }
        var parts: [String] = []
        if trimmed { parts.append("trimmed") }
        if let percent { parts.append("\(percent)%") }
        guard !parts.isEmpty else { return base }
        return "\(base) (\(parts.joined(separator: ", ")))"
    }

    /// Provenance line for a remix of another station's track.
    static func remixCredit(for track: LibraryTrack) -> String {
        let station = track.station?.name ?? "another station"
        if let url = track.webURL {
            return "Remixed from \(station) (\(url.absoluteString))"
        }
        return "Remixed from \(station)"
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
