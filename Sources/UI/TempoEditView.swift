import AVFoundation
import SwiftUI
import UIKit

/// Tap for the transport buttons, detent tick when the speed ruler crosses
/// 100%, and a confirmation buzz when the new version lands.
private enum TempoHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let detent = UIImpactFeedbackGenerator(style: .medium)
    static let confirm = UINotificationFeedbackGenerator()
}

/// Live varispeed preview of one track, streamed — playback starts in
/// seconds instead of waiting for a full download. AVPlayer's `.varispeed`
/// pitch algorithm behaves like a turntable's pitch fader: speed and pitch
/// move together with the rate. The full file is only downloaded on save.
@MainActor
final class TempoPreview: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    /// Playhead position as a fraction of the track.
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Double = 1 {
        didSet {
            // Setting a non-zero rate starts playback, so only push it
            // through while already playing.
            if isPlaying {
                player.rate = Float(rate)
            }
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(url: URL, fallbackDuration: TimeInterval) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .varispeed
        player.replaceCurrentItem(with: item)
        duration = fallbackDuration
        isReady = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.progress = min(max(time.seconds / self.duration, 0), 1)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.progress = 1
            }
        }

        // Refine the fallback duration in the background — never await it
        // here: for a remote MP3, AVFoundation computes precise duration by
        // scanning most of the file over HTTP, which can take minutes.
        Task { [weak self] in
            if let loaded = try? await asset.load(.duration), loaded.isNumeric, loaded.seconds > 0 {
                self?.duration = loaded.seconds
            }
        }
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            // Same category the track player uses; takes over cleanly.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            if progress >= 1 {
                player.seek(to: .zero)
            }
            player.playImmediately(atRate: Float(rate))
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let time = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        progress = fraction
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
    }
}

/// Streams a remote file to a temp location with byte-level progress, for
/// the save path (the offline renderer needs the whole file on disk).
enum TempoDownloader {
    static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expected = response.expectedContentLength
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 17)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 17 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    onProgress(Double(received) / Double(expected))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return destination
    }
}

/// Offline varispeed render: the preview's exact graph run faster than real
/// time into an AAC file, so what was heard is what gets saved.
enum TempoRenderer {
    enum RenderError: Error {
        case renderFailed
    }

    static func render(
        source: URL,
        rate: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: source)
            let format = file.processingFormat
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            // A single varispeed unit only accepts 0.25–4.0 (it silently
            // clamps outside that), but the wheel goes down to 4%. Cascade
            // however many stages keep each one in its legal range: the
            // rates multiply through the chain.
            let stages = rate < 0.25 ? Int(ceil(log(rate) / log(0.25))) : 1
            let perStageRate = pow(rate, 1.0 / Double(stages))
            let varispeeds = (0..<stages).map { _ in AVAudioUnitVarispeed() }
            engine.attach(player)
            varispeeds.forEach {
                $0.rate = Float(perStageRate)
                engine.attach($0)
            }
            // Every connection carries the file's format explicitly. With
            // `nil` the engine picks the node's default (hardware-rate)
            // format, and varispeed refuses to convert between the two:
            // kAudioUnitErr_FormatNotSupported (-10868).
            var upstream: AVAudioNode = player
            for varispeed in varispeeds {
                engine.connect(upstream, to: varispeed, format: format)
                upstream = varispeed
            }
            engine.connect(upstream, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: 4096
            )
            try engine.start()
            player.scheduleFile(file, at: nil)
            player.play()

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tempo-render-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let output = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: file.processingFormat.sampleRate,
                AVNumberOfChannelsKey: file.processingFormat.channelCount,
                AVEncoderBitRateKey: Config.audioBitrate,
            ])
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ) else {
                throw RenderError.renderFailed
            }

            // Varispeed resamples, so the output is shorter or longer than
            // the source by exactly the rate.
            let targetFrames = AVAudioFramePosition(Double(file.length) / rate)
            while engine.manualRenderingSampleTime < targetFrames {
                try Task.checkCancellation()
                let remaining = targetFrames - engine.manualRenderingSampleTime
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
                let status = try engine.renderOffline(count, to: buffer)
                switch status {
                case .success:
                    try output.write(from: buffer)
                    onProgress(Double(engine.manualRenderingSampleTime) / Double(targetFrames))
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw RenderError.renderFailed
                @unknown default:
                    throw RenderError.renderFailed
                }
            }
            player.stop()
            engine.stop()
            return destination
        }.value
    }
}

/// Full-page tempo editor: tall waveform with a scrubbable playhead,
/// transport, and a turntable-style speed ruler. Saving renders the sped
/// track offline and uploads it as a new version alongside the original.
struct TempoEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: LibraryTrack

    @StateObject private var preview = TempoPreview()
    @StateObject private var waveform = WaveformLoader()
    @State private var isScrubbing = false
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

    private var percent: Int {
        Int((preview.rate * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 0)

                Group {
                    if preview.isReady {
                        // Flat placeholder bars until the background level
                        // computation lands; playback never waits for it.
                        TempoWaveform(
                            levels: waveform.levels,
                            progress: preview.progress,
                            onScrub: { preview.seek(toFraction: $0) },
                            isScrubbing: $isScrubbing
                        )
                    } else {
                        ProgressView("Loading audio…")
                    }
                }
                .frame(height: 180)

                Text("\(Self.format(preview.progress * preview.duration)) / \(Self.format(preview.duration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                transport

                VStack(spacing: 10) {
                    SpeedWheel(value: $preview.rate)
                    // Varispeed changes the runtime; show where it lands.
                    Text(percent == 100
                         ? " "
                         : "\(Self.format(preview.duration)) → \(Self.format(preview.duration / preview.rate))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                saveArea
            }
            .padding(24)
            .navigationTitle("Adjust Tempo")
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
                // Levels compute from their own background download; the
                // streaming preview doesn't wait for them.
                waveform.load(key: "tempo-\(track.id)", url: url, buckets: 56)
                await preview.load(url: url, fallbackDuration: TimeInterval(track.duration ?? 0))
            }
            .onDisappear {
                preview.teardown()
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                TempoHaptics.tap.impactOccurred()
                preview.seek(toFraction: 0)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .frame(width: 64, height: 48)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                TempoHaptics.tap.impactOccurred()
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
                    Text("Rendering at \(percent)%…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .uploading(let progress):
                ProgressView(value: progress) {
                    Text("Uploading new version…")
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
                Text(percent == 100 ? "Save New Version" : "Save New Version at \(percent)%")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.eveningsRed)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!preview.isReady || percent == 100 || isSaving)
            .opacity(!preview.isReady || percent == 100 || isSaving ? 0.4 : 1)
        }
    }

    /// Downloads the original, renders the varispeed version offline, and
    /// uploads it as a fresh track next to the original — nothing is
    /// overwritten.
    private func save() {
        guard let remote = track.audioURL else { return }
        guard let token = model.credentials?.accessToken else {
            saveState = .failed("Not signed in.")
            return
        }
        preview.pause()
        let rate = preview.rate
        saveState = .downloading(0)
        Task {
            // The whole pipeline can run for minutes on a long set; if the
            // screen locks the app suspends and every socket dies. Keep the
            // screen awake, and buy grace time if the user briefly leaves.
            UIApplication.shared.isIdleTimerDisabled = true
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tempo-save")
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
                let rendered = try await TempoRenderer.render(source: source, rate: rate) { progress in
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
                phase = "upload the new version"
                saveState = .uploading(0)
                let uploaded = try await api.uploadTrack(
                    fileURL: streamable,
                    filename: "tempo-\(track.id)-\(percent).m4a",
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
                    title: "\(baseTitle) (\(percent)%)",
                    accessToken: token
                )
                await model.loadLibrary()
                TempoHaptics.confirm.notificationOccurred(.success)
                dismiss()
            } catch {
                saveState = .failed("Couldn't \(phase): \(error.localizedDescription)")
                TempoHaptics.confirm.notificationOccurred(.error)
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

/// Tall, full-height waveform with a continuous playhead and drag-to-scrub —
/// the editor-size sibling of the mini player's PlayingWaveform.
struct TempoWaveform: View {
    /// Normalized 0...1 amplitude per bar; nil draws flat placeholder bars
    /// while levels are still computing.
    let levels: [Float]?
    let progress: Double
    let onScrub: (Double) -> Void
    @Binding var isScrubbing: Bool

    @State private var scrubFraction: Double?

    private static let tick = UISelectionFeedbackGenerator()
    @State private var lastTickedBar: Int?

    private var barCount: Int { levels?.count ?? 56 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let displayed = scrubFraction ?? progress

            ZStack(alignment: .leading) {
                bars(height: geometry.size.height).opacity(0.25)
                bars(height: geometry.size.height)
                    .opacity(0.9)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(2, displayed * width))
                    }
                // The playhead line, riding the leading edge of the mask.
                Rectangle()
                    .fill(Color.eveningsRed)
                    .frame(width: 2)
                    .offset(x: min(max(displayed * width - 1, 0), width - 2))
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            Self.tick.prepare()
                        }
                        isScrubbing = true
                        let fraction = min(max(value.location.x / width, 0), 1)
                        scrubFraction = fraction
                        let bar = min(barCount - 1, Int(fraction * Double(barCount)))
                        if bar != lastTickedBar {
                            if lastTickedBar != nil {
                                Self.tick.selectionChanged()
                                Self.tick.prepare()
                            }
                            lastTickedBar = bar
                        }
                    }
                    .onEnded { value in
                        onScrub(min(max(value.location.x / width, 0), 1))
                        scrubFraction = nil
                        lastTickedBar = nil
                        isScrubbing = false
                    }
            )
        }
    }

    private func bars(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: levels.map { max(8, height * CGFloat($0[index])) } ?? 10)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: levels)
    }
}

/// Jog-wheel speed control: a fixed center needle with the tick strip
/// scrolling underneath it, like a camera dial. Dragging moves the ticks,
/// each 1% crossing clicks, 100% is a magnetic detent, double-tap resets.
struct SpeedWheel: View {
    @Binding var value: Double

    private let range: ClosedRange<Double> = 0.04...1.5
    /// Drag sensitivity and tick spacing: how many points one percent spans.
    private let pointsPerPercent: CGFloat = 7
    /// Values this close to 1.0 snap to exactly 1.0.
    private let detentWidth = 0.004
    @State private var dragStartValue: Double?
    @State private var lastTickedPercent: Int?
    @State private var inDetent = false

    private static let tick = UISelectionFeedbackGenerator()

    var body: some View {
        HStack(spacing: 16) {
            Text("Speed")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack {
                    ticks(in: geometry.size)
                        // The strip runs past both edges; fade it out so it
                        // reads as a wheel emerging from the housing.
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Capsule()
                        .fill(Color.eveningsRed)
                        .frame(width: 3, height: 34)
                }
                .contentShape(Rectangle())
                .gesture(drag)
                .onTapGesture(count: 2) {
                    TempoHaptics.detent.impactOccurred()
                    value = 1
                    inDetent = true
                }
            }
            .frame(height: 52)

            Text("\(Int((value * 100).rounded()))%")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Ticks positioned by their distance from the current value, so the
    /// whole strip slides as the value changes and the needle stays put.
    private func ticks(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let center = canvasSize.width / 2
            for percent in 4...150 {
                let offset = (Double(percent) - value * 100) * pointsPerPercent
                let x = center + CGFloat(offset)
                guard x > -4, x < canvasSize.width + 4 else { continue }
                let isMajor = percent % 10 == 0
                // Ticks shrink toward the housing's edges, curving away
                // like the visible face of a physical wheel.
                let edge = min(abs(x - center) / center, 1)
                let heightScale = 1 - 0.7 * pow(edge, 1.6)
                let tickHeight: CGFloat = (isMajor ? 24 : 12) * heightScale
                let rect = CGRect(
                    x: x - 0.5,
                    y: (canvasSize.height - tickHeight) / 2,
                    width: isMajor ? 1.5 : 1,
                    height: tickHeight
                )
                let color: Color = percent == 100
                    ? .secondary.opacity(0.9)
                    : .secondary.opacity(isMajor ? 0.55 : 0.28)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartValue == nil {
                    dragStartValue = value
                    lastTickedPercent = Int((value * 100).rounded())
                    Self.tick.prepare()
                    TempoHaptics.detent.prepare()
                }
                // Dragging the strip right moves the needle down the scale,
                // like spinning a physical dial.
                let delta = -Double(gesture.translation.width / pointsPerPercent) / 100
                var next = (dragStartValue ?? value) + delta
                next = min(max(next, range.lowerBound), range.upperBound)
                if abs(next - 1) < detentWidth {
                    next = 1
                    if !inDetent {
                        TempoHaptics.detent.impactOccurred()
                        inDetent = true
                    }
                } else {
                    inDetent = false
                }
                let percent = Int((next * 100).rounded())
                if percent != lastTickedPercent {
                    Self.tick.selectionChanged()
                    Self.tick.prepare()
                    lastTickedPercent = percent
                }
                value = next
            }
            .onEnded { _ in
                dragStartValue = nil
                lastTickedPercent = nil
            }
    }
}
