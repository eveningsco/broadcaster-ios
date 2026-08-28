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
/// seconds instead of waiting for a full download, yet played through an
/// AVAudioEngine varispeed graph so wheel movements bend the audio within a
/// render quantum (~6 ms) — the turntable-under-your-finger feel AVPlayer's
/// rate property can't deliver. The track streams to a temp file while a
/// feeder decodes the growing file into 1-second buffers scheduled a few
/// seconds ahead of the playhead.
@MainActor
final class TempoPreview: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    /// Playhead position as a fraction of the track.
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Double = 1 {
        didSet { varispeed.rate = Float(rate) }
    }

    /// The fully-downloaded original once the stream finishes; the save
    /// path uses it to skip a second download.
    private(set) var completedFileURL: URL?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()

    /// The growing temp download (or the local file itself for drafts).
    private var localURL: URL?
    private var ownsLocalFile = false
    private var format: AVAudioFormat?
    private var sampleRate: Double = 44_100
    /// Estimated until the download completes, then exact.
    private var totalFrames: AVAudioFramePosition = 0
    private var downloadComplete = false

    private var downloadTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?
    private var ticker: Timer?

    /// Where the current play run began, in source frames; the player node
    /// reports time relative to this.
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    /// Next source frame the feeder will read (wraps when looping).
    private var feedFrame: AVAudioFramePosition = 0
    /// Total frames scheduled since this play run began.
    private var scheduledFrames: AVAudioFramePosition = 0
    /// Buffers scheduled but not yet consumed by the player.
    private var pendingChunks = 0
    /// True when the feeder has scheduled everything through end of track.
    private var feederDone = false
    /// Invalidates stale feeders and buffer callbacks after stop/seek.
    private var generation = UUID()

    /// Loop region for the trim editor, as fractions of the track; nil
    /// plays straight through (the tempo editor's mode). Frames derive
    /// from these whenever the total-length estimate improves.
    private var loopFractions: (start: Double, end: Double)?
    private var loopStart: AVAudioFramePosition = 0
    private var loopEnd: AVAudioFramePosition = 0

    private let chunkSeconds = 1.0

    var sourceFileURL: URL? { localURL }
    var isDownloadComplete: Bool { downloadComplete }

    private var isLooping: Bool { loopEnd > loopStart }

    /// Audible-scrub state: while the finger drags the waveform, playback
    /// follows it — forward audio moving right, reversed audio moving left,
    /// resampled to the drag speed like shuttling tape.
    private var isScrubbing = false
    private var scrubFile: AVAudioFile?
    private var scrubLastFrame: AVAudioFramePosition = 0
    private var scrubLastTime: CFAbsoluteTime = 0
    private var scrubPending = 0
    private var wasPlayingBeforeScrub = false
    /// Smoothed playback speed while scrubbing; pitch follows the finger's
    /// velocity through this.
    private var scrubSpeed = 1.0

    /// Scrub gearing: dragging this fraction of the strip per second plays
    /// at normal pitch. Faster drags pitch up (to the cap), slower drags
    /// sink toward the floor.
    private static let referenceScrubSpeed = 0.25
    private static let minScrubSpeed = 0.15
    private static let maxScrubSpeed = 3.0

    func load(url: URL, fallbackDuration: TimeInterval) async {
        duration = fallbackDuration
        if url.isFileURL {
            localURL = url
            downloadComplete = true
            completedFileURL = url
            prepareGraphIfPossible()
            return
        }

        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-src-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        localURL = destination
        ownsLocalFile = true

        // Detached: the chunk loop must never run on the main actor, or a
        // long download starves the UI (and itself).
        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                var written = 0
                var nextPrepareAt = 1 << 17
                var ready = false
                for try await event in AudioChunkStream.events(from: url) {
                    guard case .chunk(let data) = event else { continue }
                    try Task.checkCancellation()
                    try handle.write(contentsOf: data)
                    written += data.count
                    // Until the graph is up, try opening the partial file
                    // every 128 KB; once ready, stop hopping to main.
                    if !ready, written >= nextPrepareAt {
                        nextPrepareAt = written + (1 << 17)
                        ready = await MainActor.run { [weak self] in
                            self?.prepareGraphIfPossible()
                            return self?.isReady ?? true
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloadComplete = true
                    self.completedFileURL = destination
                    self.prepareGraphIfPossible()
                    // The full file is on disk; replace the estimate.
                    if let file = try? AVAudioFile(forReading: destination) {
                        self.totalFrames = file.length
                        self.duration = Double(file.length) / file.processingFormat.sampleRate
                        self.applyLoopFrames()
                    }
                }
            } catch {
                // Streaming preview failed; the editor stays in its
                // loading state. (Cancellation lands here too.)
            }
        }
    }

    /// Builds the engine graph as soon as enough of the file is on disk for
    /// the decoder to open it (a few hundred KB of MP3).
    private func prepareGraphIfPossible() {
        guard !isReady, let localURL,
              let file = try? AVAudioFile(forReading: localURL) else { return }
        let format = file.processingFormat
        self.format = format
        sampleRate = format.sampleRate
        if downloadComplete {
            totalFrames = file.length
            duration = Double(file.length) / format.sampleRate
        } else {
            // A partial file underreports its length; trust the server's
            // duration for the full span.
            totalFrames = max(file.length, AVAudioFramePosition(duration * format.sampleRate))
        }
        engine.attach(player)
        engine.attach(varispeed)
        varispeed.rate = Float(rate)
        // Explicit formats everywhere — varispeed refuses converting
        // connections (kAudioUnitErr_FormatNotSupported).
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        engine.prepare()
        applyLoopFrames()
        isReady = true
    }

    /// Sets (or moves) the looping audition region. While playing, the run
    /// restarts from the current position clamped into the new region.
    func setLoop(startFraction: Double, endFraction: Double) {
        loopFractions = (startFraction, endFraction)
        applyLoopFrames()
        if isPlaying {
            play(from: currentFrame)
        } else if totalFrames > 0 {
            pausedFrame = min(max(pausedFrame, loopStart), loopEnd)
            updateProgress()
        }
    }

    private func applyLoopFrames() {
        guard let loopFractions, totalFrames > 0 else { return }
        loopStart = AVAudioFramePosition(loopFractions.start * Double(totalFrames))
        loopEnd = AVAudioFramePosition(loopFractions.end * Double(totalFrames))
    }

    func toggle() {
        guard !isScrubbing else { return }
        if isPlaying {
            pause()
        } else {
            var frame = pausedFrame
            if totalFrames > 0, frame >= totalFrames {
                frame = 0
            }
            play(from: frame)
        }
    }

    func pause() {
        guard isPlaying, !isScrubbing else { return }
        pausedFrame = currentFrame
        stopPlayback()
        updateProgress()
    }

    func seek(toFraction fraction: Double) {
        guard totalFrames > 0, !isScrubbing else { return }
        let frame = AVAudioFramePosition(fraction * Double(totalFrames))
        if isPlaying {
            play(from: frame)
        } else {
            pausedFrame = frame
        }
        // Reflect the new position in this same frame — waiting for the
        // next ticker tick lets the needle flash at its old spot between
        // scrub release and the first tick.
        updateProgress()
    }

    func teardown() {
        downloadTask?.cancel()
        isScrubbing = false
        scrubFile = nil
        stopPlayback()
        engine.stop()
        if ownsLocalFile, let localURL {
            try? FileManager.default.removeItem(at: localURL)
        }
        localURL = nil
        completedFileURL = nil
    }

    // MARK: - Audible scrubbing

    func beginScrub() {
        guard isReady, !isScrubbing, let localURL else { return }
        wasPlayingBeforeScrub = isPlaying
        scrubLastFrame = currentFrame
        scrubLastTime = CFAbsoluteTimeGetCurrent()
        // Take over the player node for ad-hoc scrub buffers; normal
        // playback resumes from wherever the finger lets go.
        generation = UUID()
        feederTask?.cancel()
        ticker?.invalidate()
        player.stop()
        scrubPending = 0
        scrubSpeed = 1
        scrubFile = try? AVAudioFile(forReading: localURL)
        isScrubbing = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
        player.play()
    }

    func scrubTo(fraction: Double) {
        guard isScrubbing, let scrubFile, let format, totalFrames > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - scrubLastTime, 0.01), 0.2)
        let target = min(
            AVAudioFramePosition(fraction * Double(totalFrames)),
            max(0, scrubFile.length - 1)
        )
        progress = min(max(fraction, 0), 1)
        let delta = target - scrubLastFrame
        // Sub-audible movement: let it accumulate until it's worth a sound.
        guard abs(delta) > 128 else { return }
        scrubLastTime = now
        if scrubPending >= 4 {
            // Scheduling backlog — skip this segment rather than lag.
            scrubLastFrame = target
            return
        }
        // Pitch rides the finger's velocity: gesture speed relative to the
        // reference gearing sets the resample ratio, smoothed so touch
        // jitter doesn't warble. Raw track-per-point physics would pin a
        // zoomed-out strip at chipmunk speeds, so the gearing is gestural,
        // not physical. Position still glues to the finger — fast flicks
        // skip audio rather than compressing it.
        let outputFrames = AVAudioFramePosition(max(256, Int(dt * sampleRate)))
        let fractionPerSecond = abs(Double(delta) / Double(totalFrames)) / dt
        let rawSpeed = min(
            max(fractionPerSecond / Self.referenceScrubSpeed, Self.minScrubSpeed),
            Self.maxScrubSpeed
        )
        scrubSpeed = scrubSpeed * 0.5 + rawSpeed * 0.5
        let span = max(128, AVAudioFramePosition(Double(outputFrames) * scrubSpeed))
        let readStart = delta >= 0 ? target - span : target
        guard readStart >= 0,
              let source = Self.readFrames(
                file: scrubFile,
                from: readStart,
                frames: AVAudioFrameCount(span),
                format: format
              ),
              let buffer = Self.makeScrubBuffer(
                from: source,
                outputFrames: AVAudioFrameCount(outputFrames),
                reversed: delta < 0,
                format: format
              ) else {
            scrubLastFrame = target
            return
        }
        scrubPending += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in
            Task { @MainActor [weak self] in
                self?.scrubPending -= 1
            }
        }
        scrubLastFrame = target
    }

    func endScrub(at fraction: Double) {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubFile = nil
        player.stop()
        guard totalFrames > 0 else { return }
        let frame = AVAudioFramePosition(min(max(fraction, 0), 1) * Double(totalFrames))
        if wasPlayingBeforeScrub {
            play(from: frame)
        } else {
            pausedFrame = frame
        }
        updateProgress()
    }

    /// Random-access read from the persistent scrub handle.
    private nonisolated static func readFrames(
        file: AVAudioFile,
        from frame: AVAudioFramePosition,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard frame >= 0, frame < file.length, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        file.framePosition = frame
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            // Truncated reads keep whatever decoded; silence past the edge.
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Squeezes (or stretches) the dragged-over source span into a buffer
    /// lasting as long as the drag segment did — the resampling IS the
    /// scratch pitch. Reversed spans read back to front, and short linear
    /// ramps at both ends keep chunk seams from clicking.
    private nonisolated static func makeScrubBuffer(
        from source: AVAudioPCMBuffer,
        outputFrames: AVAudioFrameCount,
        reversed: Bool,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let n = Int(source.frameLength)
        let m = Int(outputFrames)
        guard n > 1, m > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames),
              let src = source.floatChannelData,
              let dst = out.floatChannelData else {
            return nil
        }
        let channels = Int(format.channelCount)
        let rampLength = min(64, m / 4)
        for o in 0..<m {
            var position = Double(o) / Double(max(1, m - 1)) * Double(n - 1)
            if reversed {
                position = Double(n - 1) - position
            }
            let i0 = Int(position)
            let i1 = min(i0 + 1, n - 1)
            let t = Float(position - Double(i0))
            var ramp: Float = 1
            if rampLength > 0 {
                if o < rampLength {
                    ramp = Float(o) / Float(rampLength)
                } else if o >= m - rampLength {
                    ramp = Float(m - 1 - o) / Float(rampLength)
                }
            }
            for channel in 0..<channels {
                let sample = src[channel][i0] * (1 - t) + src[channel][i1] * t
                dst[channel][o] = sample * ramp
            }
        }
        out.frameLength = outputFrames
        return out
    }

    // MARK: - Playback internals

    private func play(from frame: AVAudioFramePosition) {
        guard isReady else { return }
        var frame = frame
        if isLooping {
            frame = min(max(frame, loopStart), max(loopStart, loopEnd - 1))
        }
        // Same category the track player uses; takes over cleanly.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
        generation = UUID()
        player.stop()
        pendingChunks = 0
        feederDone = false
        startFrame = frame
        pausedFrame = frame
        feedFrame = frame
        scheduledFrames = 0
        player.play()
        isPlaying = true
        startFeeder()
        startTicker()
    }

    private func stopPlayback() {
        generation = UUID()
        feederTask?.cancel()
        player.stop()
        isPlaying = false
        ticker?.invalidate()
    }

    /// Keeps a few seconds of decoded audio scheduled ahead of the
    /// playhead, reading from the still-growing download. When it hits the
    /// download's edge it waits for more bytes; the audio pauses there and
    /// resumes as the stream catches up. With a loop region set, reads are
    /// capped at the out-point and wrap back to the in-point — buffers
    /// chain gaplessly, so the loop is seamless.
    private func startFeeder() {
        feederTask?.cancel()
        let token = generation
        feederTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == token {
                if self.pendingChunks >= 3 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                guard let localURL = self.localURL, let format = self.format else { break }
                var frames = AVAudioFrameCount(self.sampleRate * self.chunkSeconds)
                if self.isLooping {
                    let toLoopEnd = max(1, self.loopEnd - self.feedFrame)
                    frames = AVAudioFrameCount(min(AVAudioFramePosition(frames), toLoopEnd))
                }
                if let chunk = Self.readChunk(url: localURL, from: self.feedFrame, frames: frames, format: format) {
                    self.pendingChunks += 1
                    self.scheduledFrames += AVAudioFramePosition(chunk.frameLength)
                    self.feedFrame += AVAudioFramePosition(chunk.frameLength)
                    if self.isLooping, self.feedFrame >= self.loopEnd {
                        self.feedFrame = self.loopStart
                    }
                    self.player.scheduleBuffer(chunk, completionCallbackType: .dataConsumed) { _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.pendingChunks -= 1
                        }
                    }
                } else if self.downloadComplete {
                    if self.isLooping, self.feedFrame != self.loopStart {
                        // The out-point sits past the file's real end (the
                        // length was an estimate) — wrap instead of ending.
                        self.feedFrame = self.loopStart
                        continue
                    }
                    guard !self.isLooping else {
                        // Loop region unreadable even from its start;
                        // nothing to schedule.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        continue
                    }
                    // Nothing left to read: the track is fully scheduled.
                    self.feederDone = true
                    break
                } else {
                    // Caught up with the download; wait for more bytes.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
        }
    }

    /// One decoded chunk from the (possibly still truncated) file. Reads
    /// that run past the truncation point throw or come back empty; the
    /// caller retries once more bytes land.
    private nonisolated static func readChunk(
        url: URL,
        from frame: AVAudioFramePosition,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              frame < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        file.framePosition = frame
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            // Partial reads still fill the buffer up to the failure point.
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Source frames consumed so far: the player node counts frames it has
    /// handed to varispeed, which are source frames — so this advances
    /// faster at higher rates. Clamped to what's actually scheduled so an
    /// underrun at the download edge doesn't run the clock ahead. With a
    /// loop active, elapsed frames fold back into the region.
    private var currentFrame: AVAudioFramePosition {
        if isScrubbing {
            return scrubLastFrame
        }
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return pausedFrame
        }
        let elapsed = min(max(playerTime.sampleTime, 0), scheduledFrames)
        if isLooping {
            let length = loopEnd - loopStart
            guard length > 0 else { return loopStart }
            return loopStart + (startFrame - loopStart + elapsed) % length
        }
        return max(startFrame + elapsed, 0)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        updateProgress()
        // End of track: everything scheduled and played through. A loop
        // never ends on its own.
        if isPlaying, !isLooping, feederDone, pendingChunks == 0,
           let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           playerTime.sampleTime >= scheduledFrames {
            pausedFrame = totalFrames
            stopPlayback()
            progress = 1
        }
    }

    private func updateProgress() {
        guard totalFrames > 0 else { return }
        progress = min(max(Double(currentFrame) / Double(totalFrames), 0), 1)
    }
}

/// Native-speed chunked download stream. URLSession's AsyncBytes hands out
/// one byte per iteration — CPU-bound and brutally slow in debug builds —
/// so this wraps a data-task delegate that yields whole Data chunks as the
/// network delivers them.
enum AudioChunkStream {
    enum Event {
        case response(expectedBytes: Int64)
        case chunk(Data)
    }

    static func events(from url: URL) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let delegate = Delegate(continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        private let continuation: AsyncThrowingStream<Event, Error>.Continuation

        init(continuation: AsyncThrowingStream<Event, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            continuation.yield(.response(expectedBytes: response.expectedContentLength))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.chunk(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
            session.finishTasksAndInvalidate()
        }
    }
}

/// Streams a remote file to a temp location with byte-level progress, for
/// the save path (the offline renderer needs the whole file on disk).
enum TempoDownloader {
    static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var expected: Int64 = -1
        var received: Int64 = 0
        for try await event in AudioChunkStream.events(from: url) {
            switch event {
            case .response(let expectedBytes):
                expected = expectedBytes
            case .chunk(let data):
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                if expected > 0 {
                    onProgress(Double(received) / Double(expected))
                }
            }
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
            let output = try AACBufferWriter(url: destination, source: engine.manualRenderingFormat)
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
                    try output.write(buffer)
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
            try output.finish()
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
                            onScrubBegin: { preview.beginScrub() },
                            onScrubMove: { preview.scrubTo(fraction: $0) },
                            onScrub: { preview.endScrub(at: $0) },
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
                        .font(.social(.footnote))
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
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                }
            case .rendering(let progress):
                ProgressView(value: progress) {
                    Text("Rendering at \(percent)%…")
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
                Text(percent == 100 ? "Save New Version" : "Save New Version at \(percent)%")
                    .font(.social(.body, weight: .bold))
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
                if track.owner != true {
                    // Someone else's track: name it a remix and stamp
                    // provenance in the description.
                    try? await api.updateTrack(
                        id: uploaded.id,
                        title: "\(baseTitle) (remix \(percent)%)",
                        description: TrimEditSheet.remixCredit(for: track),
                        accessToken: token
                    )
                } else {
                    try? await api.updateTrackTitle(
                        id: uploaded.id,
                        title: "\(baseTitle) (\(percent)%)",
                        accessToken: token
                    )
                }
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
    /// Finger touched down / is moving — drives the audible scrub.
    var onScrubBegin: (() -> Void)?
    var onScrubMove: ((Double) -> Void)?
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
                            onScrubBegin?()
                        }
                        isScrubbing = true
                        let fraction = min(max(value.location.x / width, 0), 1)
                        scrubFraction = fraction
                        onScrubMove?(fraction)
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
                .font(.social(.subheadline))
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
                .font(.social(.subheadline, weight: .medium))
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
