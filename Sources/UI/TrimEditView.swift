import AVFoundation
import SwiftUI
import UIKit

/// Tap for transport, ticks while dragging handles, and a confirmation
/// buzz when the trimmed version lands.
private enum TrimHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let grab = UIImpactFeedbackGenerator(style: .medium)
    static let tick = UISelectionFeedbackGenerator()
    static let confirm = UINotificationFeedbackGenerator()
}

/// Decodes the preview's growing download into per-bucket levels on a
/// polling timer, so the real waveform fills in left to right off the one
/// stream. Each pass reads only newly-arrived frames (carry-over state),
/// keeping total work linear.
@MainActor
final class IncrementalWaveform: ObservableObject {
    @Published private(set) var levels: [Float]?

    private var timer: Timer?
    private var busy = false
    private var state = DecodeState(buckets: 56)
    private var fileURL: URL?
    private var durationHint: TimeInterval = 0
    private var isComplete: (() -> Bool)?

    func begin(fileURL: URL, duration: TimeInterval, isComplete: @escaping () -> Bool) {
        guard timer == nil else { return }
        self.fileURL = fileURL
        durationHint = duration
        self.isComplete = isComplete
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pass()
            }
        }
        // First pass right away rather than 1.5s from now.
        pass()
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
    }

    private func pass() {
        guard !busy, let fileURL else { return }
        busy = true
        let wasComplete = isComplete?() ?? false
        var carried = state
        let hint = durationHint
        Task.detached(priority: .utility) { [weak self] in
            let levels = Self.decodeMore(from: fileURL, state: &carried, totalDurationHint: hint)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.state = carried
                if let levels {
                    self.levels = levels
                }
                self.busy = false
                // The pass that ran after completion has read every frame.
                if wasComplete {
                    self.teardown()
                }
            }
        }
    }

    private struct DecodeState {
        var sums: [Double]
        var counts: [Int]
        var nextFrame: AVAudioFramePosition = 0
        var framesPerBucket: AVAudioFramePosition = 0
        var buckets: Int

        init(buckets: Int) {
            self.buckets = buckets
            sums = [Double](repeating: 0, count: buckets)
            counts = [Int](repeating: 0, count: buckets)
        }
    }

    /// Reads whatever new audio is on disk into the running per-bucket RMS.
    /// Reads past the truncation point end the pass; the next one resumes
    /// at the same frame.
    private nonisolated static func decodeMore(
        from url: URL,
        state: inout DecodeState,
        totalDurationHint: Double
    ) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        if state.framesPerBucket == 0 {
            // A partial file underreports its length; the bucket grid must
            // span the full track, so prefer the known duration.
            let hinted = AVAudioFramePosition(totalDurationHint * format.sampleRate)
            let total = max(hinted, file.length)
            guard total > 0 else { return nil }
            state.framesPerBucket = max(1, total / AVAudioFramePosition(state.buckets))
        }
        let channels = Int(format.channelCount)
        guard channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 17) else {
            return nil
        }
        file.framePosition = state.nextFrame
        let sampleStride = 16

        while true {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var i = (sampleStride - Int(state.nextFrame) % sampleStride) % sampleStride
            while i < frameCount {
                let globalFrame = state.nextFrame + AVAudioFramePosition(i)
                let bucket = min(state.buckets - 1, Int(globalFrame / state.framesPerBucket))
                var sample: Float = 0
                for channel in 0..<channels {
                    sample += data[channel][i] * data[channel][i]
                }
                state.sums[bucket] += Double(sample) / Double(channels)
                state.counts[bucket] += 1
                i += sampleStride
            }
            state.nextFrame += AVAudioFramePosition(frameCount)
        }

        let rms = zip(state.sums, state.counts).map { sum, count in
            count > 0 ? sqrt(sum / Double(count)) : 0
        }
        guard let peak = rms.max(), peak > 0 else { return nil }
        return rms.map { Float(pow($0 / peak, 0.7)) }
    }
}

/// Copies the selected frame range of the source into a fresh AAC file —
/// no processing graph, just a read-write loop, so it runs far faster than
/// real time.
enum TrimRenderer {
    enum RenderError: Error {
        case emptySelection
    }

    static func render(
        source: URL,
        startFraction: Double,
        endFraction: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: source)
            let total = file.length
            let startFrame = AVAudioFramePosition((Double(total) * startFraction).rounded())
            let endFrame = AVAudioFramePosition((Double(total) * endFraction).rounded())
            guard endFrame > startFrame else {
                throw RenderError.emptySelection
            }
            let format = file.processingFormat

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("trim-render-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let output = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: Config.audioBitrate,
            ])
            let capacity: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw RenderError.emptySelection
            }

            file.framePosition = startFrame
            let totalOut = endFrame - startFrame
            var remaining = totalOut
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
                try file.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
                onProgress(1 - Double(remaining) / Double(totalOut))
            }
            return destination
        }.value
    }
}

/// Full-page trim editor: the whole track in a fixed strip with in/out
/// handles and a looping audition between them. Saving copies the selection
/// into a new track next to the untouched original.
struct TrimEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: LibraryTrack

    @StateObject private var preview = TempoPreview()
    @StateObject private var waveform = IncrementalWaveform()
    /// Selection as fractions of the track.
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var saveState: SaveState = .idle

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

    /// Selection must move before saving means anything.
    private var hasSelection: Bool {
        trimStart > 0.0005 || trimEnd < 0.9995
    }

    private var minGapFraction: Double {
        preview.duration > 0 ? min(5 / preview.duration, 1) : 0.01
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 0)

                Group {
                    if preview.isReady {
                        TrimStrip(
                            start: $trimStart,
                            end: $trimEnd,
                            progress: preview.progress,
                            levels: waveform.levels,
                            minGap: minGapFraction,
                            onScrub: { preview.seek(toFraction: $0) },
                            onHandleMoved: { commitSelection() }
                        )
                    } else {
                        ProgressView("Loading audio…")
                    }
                }
                .frame(height: 132)

                readouts

                transport

                Spacer(minLength: 0)

                saveArea
            }
            .padding(24)
            .navigationTitle("Trim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .task {
                // The mini player and the preview can't share the output.
                model.player.pause()
                guard let url = track.audioURL else { return }
                await preview.load(url: url, fallbackDuration: TimeInterval(track.duration ?? 0))
                preview.setLoop(startFraction: trimStart, endFraction: trimEnd)
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

    private var selectedDuration: TimeInterval {
        max(0, (trimEnd - trimStart) * preview.duration)
    }

    private var readouts: some View {
        HStack(spacing: 0) {
            nudger(
                label: "In",
                time: trimStart * preview.duration,
                onNudge: { delta in
                    let step = preview.duration > 0 ? delta / preview.duration : 0
                    trimStart = min(max(trimStart + step, 0), trimEnd - minGapFraction)
                    commitSelection()
                }
            )
            Spacer()
            VStack(spacing: 2) {
                Text(Self.format(selectedDuration))
                    .font(.system(.body, design: .monospaced))
                Text("selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            nudger(
                label: "Out",
                time: trimEnd * preview.duration,
                onNudge: { delta in
                    let step = preview.duration > 0 ? delta / preview.duration : 0
                    trimEnd = min(max(trimEnd + step, trimStart + minGapFraction), 1)
                    commitSelection()
                }
            )
        }
    }

    /// A time readout flanked by ±1 s chevrons for fine adjustment — the
    /// strip is far too coarse for second-level cuts on a long set.
    private func nudger(
        label: String,
        time: TimeInterval,
        onNudge: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    TrimHaptics.tick.selectionChanged()
                    onNudge(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(Self.format(time))
                    .font(.system(.body, design: .monospaced))
                Button {
                    TrimHaptics.tick.selectionChanged()
                    onNudge(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                TrimHaptics.tap.impactOccurred()
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
                TrimHaptics.tap.impactOccurred()
                preview.toggle()
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 96, height: 48)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .disabled(!preview.isReady)
    }

    @ViewBuilder
    private var saveArea: some View {
        VStack(spacing: 12) {
            switch saveState {
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading original…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .rendering(let progress):
                ProgressView(value: progress) {
                    Text("Trimming…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .uploading(let progress):
                ProgressView(value: progress) {
                    Text("Uploading trimmed version…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.eveningsRed)
            case .idle:
                EmptyView()
            }

            Button(action: save) {
                Text("Save Trimmed Version")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.eveningsRed)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!preview.isReady || !hasSelection || isSaving)
            .opacity(!preview.isReady || !hasSelection || isSaving ? 0.4 : 1)
        }
    }

    private func commitSelection() {
        preview.setLoop(startFraction: trimStart, endFraction: trimEnd)
    }

    /// Copies the selection into a fresh file and uploads it as a new
    /// track next to the original — nothing is overwritten.
    private func save() {
        guard let remote = track.audioURL else { return }
        guard let token = model.credentials?.accessToken else {
            saveState = .failed("Not signed in.")
            return
        }
        preview.pause()
        let startFraction = trimStart
        let endFraction = trimEnd
        saveState = .downloading(0)
        Task {
            // Keep the screen awake for the whole pipeline; a lock would
            // suspend the app and kill the transfer.
            UIApplication.shared.isIdleTimerDisabled = true
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "trim-save")
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
                phase = "trim the selection"
                saveState = .rendering(0)
                let rendered = try await TrimRenderer.render(
                    source: source,
                    startFraction: startFraction,
                    endFraction: endFraction
                ) { progress in
                    Task { @MainActor in
                        if case .rendering = saveState {
                            saveState = .rendering(progress)
                        }
                    }
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
                phase = "upload the trimmed version"
                saveState = .uploading(0)
                let uploaded = try await api.uploadTrack(
                    fileURL: streamable,
                    filename: "trim-\(track.id).m4a",
                    accessToken: token
                ) { progress in
                    Task { @MainActor in
                        if case .uploading = saveState {
                            saveState = .uploading(progress)
                        }
                    }
                }
                let baseTitle = track.title ?? "Untitled"
                try? await api.updateTrackTitle(
                    id: uploaded.id,
                    title: "\(baseTitle) (trimmed)",
                    accessToken: token
                )
                await model.loadLibrary()
                TrimHaptics.confirm.notificationOccurred(.success)
                dismiss()
            } catch {
                saveState = .failed("Couldn't \(phase): \(error.localizedDescription)")
                TrimHaptics.confirm.notificationOccurred(.error)
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
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

/// The Voice Memos-style trim strip: the whole track in a rounded housing,
/// white in/out handles, and a yellow playhead riding the looping audition.
/// One drag gesture serves all three — whichever target is nearest at
/// touch-down wins, handles taking priority within their grab zone.
struct TrimStrip: View {
    @Binding var start: Double
    @Binding var end: Double
    /// Playhead position as a fraction of the whole track.
    let progress: Double
    let levels: [Float]?
    /// Smallest allowed selection, as a fraction.
    let minGap: Double
    /// Playhead released after a scrub.
    let onScrub: (Double) -> Void
    /// A handle finished moving.
    let onHandleMoved: () -> Void

    private enum Target {
        case start
        case end
        case playhead
    }

    @State private var active: Target?
    @State private var scrubPreview: Double?
    @State private var lastTickedStep: Int?

    private var barCount: Int { levels?.count ?? 56 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let displayedProgress = min(max(scrubPreview ?? progress, start), end)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                bars(width: width, height: height)

                // In/out handles.
                handle(height: height)
                    .position(x: max(6, start * width), y: height / 2)
                handle(height: height)
                    .position(x: min(width - 6, end * width), y: height / 2)

                // Playhead, only meaningful inside the selection.
                Capsule()
                    .fill(Color.yellow)
                    .frame(width: 4, height: height - 28)
                    .position(x: displayedProgress * width, y: height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if active == nil {
                            active = target(at: gesture.startLocation.x, width: width)
                            TrimHaptics.grab.impactOccurred(intensity: 0.7)
                            TrimHaptics.tick.prepare()
                            lastTickedStep = nil
                        }
                        let fraction = min(max(gesture.location.x / width, 0), 1)
                        switch active {
                        case .start:
                            start = min(fraction, end - minGap)
                            tickIfNeeded(fraction: start)
                        case .end:
                            end = max(fraction, start + minGap)
                            tickIfNeeded(fraction: end)
                        case .playhead:
                            scrubPreview = min(max(fraction, start), end)
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in
                        switch active {
                        case .start, .end:
                            onHandleMoved()
                        case .playhead:
                            if let scrubPreview {
                                onScrub(scrubPreview)
                            }
                        case nil:
                            break
                        }
                        scrubPreview = nil
                        active = nil
                        lastTickedStep = nil
                    }
            )
        }
    }

    /// Handles win within their grab zone (nearer one on overlap);
    /// anywhere else moves the playhead.
    private func target(at x: CGFloat, width: CGFloat) -> Target {
        let startDistance = abs(x - start * width)
        let endDistance = abs(x - end * width)
        let grabZone: CGFloat = 32
        if min(startDistance, endDistance) <= grabZone {
            return startDistance <= endDistance ? .start : .end
        }
        return .playhead
    }

    /// A selection tick each 0.5% of travel, so dragging a handle feels
    /// ratcheted like the tempo wheel.
    private func tickIfNeeded(fraction: Double) {
        let step = Int(fraction * 200)
        if step != lastTickedStep {
            if lastTickedStep != nil {
                TrimHaptics.tick.selectionChanged()
                TrimHaptics.tick.prepare()
            }
            lastTickedStep = step
        }
    }

    private func handle(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 5, height: height - 20)
            .shadow(color: .black.opacity(0.35), radius: 2)
    }

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<barCount, id: \.self) { index in
                let barFraction = (Double(index) + 0.5) / Double(barCount)
                let inSelection = barFraction >= start && barFraction <= end
                Capsule()
                    .fill(.primary)
                    .frame(
                        width: 2.5,
                        height: levels.map { max(6, (height - 44) * CGFloat($0[index])) } ?? 8
                    )
                    .frame(maxWidth: .infinity)
                    .opacity(inSelection ? 0.9 : 0.25)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.25), value: levels)
    }
}
