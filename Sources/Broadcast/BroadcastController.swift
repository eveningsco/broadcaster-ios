import AVFAudio
import Accelerate
import Foundation
import HaishinKit
import os
import RTMPHaishinKit

/// Thread-safe holder for an audio-thread buffer consumer (the recording file
/// writer). The tap callback runs on the audio thread; the sink is installed
/// and removed from the main actor.
final class AudioSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func set(_ newSink: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    func send(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(buffer, when)
    }
}

enum CaptureError: LocalizedError {
    case inputNotReady

    var errorDescription: String? {
        switch self {
        case .inputNotReady:
            return "The audio input is still connecting. Try again in a moment."
        }
    }
}

enum BroadcastState: Equatable {
    case idle
    case connecting
    case live(since: Date)
    case reconnecting(attempt: Int)
    case stopping

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

/// Owns the capture -> encode -> RTMP pipeline and its reconnection loop.
///
/// Every TCP drop ends the server-side session (finalizing a recording), so the
/// client keeps retrying with backoff until it's back on air. A new publish with
/// the same key takes over a half-open stale session on the server.
@MainActor
final class BroadcastController: ObservableObject {
    @Published private(set) var state: BroadcastState = .idle
    @Published private(set) var levelDb: Float = -160
    @Published private(set) var lastError: String?
    /// Input ports the session can capture from (built-in mic, headset, USB
    /// interface, ...). Only meaningful once the session is configured.
    @Published private(set) var availableInputs: [AVAudioSessionPortDescription] = []
    /// UID of the port currently feeding the input route.
    @Published private(set) var currentInputUID: String?
    /// Set while live when the connection is up but audio isn't reaching the
    /// server (the encoder produced nothing), so the host doesn't broadcast
    /// dead air thinking they're on.
    @Published private(set) var audioWarning: String?

    private let engine = AVAudioEngine()
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var sessionTask: Task<Void, Never>?
    private var streamKey = ""
    private var isMonitoring = false
    private var observersInstalled = false
    // External consumers (the recorder) that need capture to stay alive even
    // when monitoring would otherwise stop (e.g. the library sheet expanding).
    private var captureHolds = 0

    /// Buffers fan out here on the audio thread (recording file writer).
    let bufferSink = AudioSinkBox()
    /// Normalizes capture for the RTMP encoder; used only on the audio thread.
    private let streamConformer = StreamAudioConformer()

    var captureFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Keep capture running regardless of monitoring state (recorder holds
    /// this while a recording is in progress).
    func retainCapture() throws {
        try configureAudioSession()
        try startCapture()
        captureHolds += 1
    }

    func releaseCapture() {
        captureHolds = max(0, captureHolds - 1)
        if captureHolds == 0 && !isMonitoring && !state.isActive {
            stopCapture()
        }
    }

    /// Run the capture path without streaming so the level meter is live before
    /// going on air (pre-flight mic check).
    func startMonitoring() {
        guard !state.isActive, !isMonitoring else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, granted, !self.state.isActive, !self.isMonitoring else { return }
                do {
                    try await self.startCaptureWithRetry()
                    self.isMonitoring = true
                } catch {
                    self.lastError = "Microphone unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopMonitoring() {
        guard isMonitoring, !state.isActive else { return }
        isMonitoring = false
        if captureHolds == 0 {
            stopCapture()
        }
    }

    /// Routes capture to the given port. The engine restarts itself via the
    /// configuration-change observer if the format changes.
    func selectInput(_ input: AVAudioSessionPortDescription) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(input)
        } catch {
            lastError = "Couldn't switch input: \(error.localizedDescription)"
        }
        refreshInputs()
    }

    private func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        availableInputs = session.availableInputs ?? []
        currentInputUID = session.currentRoute.inputs.first?.uid
    }

    func start(streamKey: String) {
        guard !state.isActive else { return }
        self.streamKey = streamKey
        // The broadcast session owns capture from here on.
        isMonitoring = false
        lastError = nil
        audioWarning = nil
        state = .connecting

        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    /// Screenshot mode only (see ScreenshotMode): show a broadcast state and
    /// meter level without touching the audio session or the network.
    func setScreenshotState(_ state: BroadcastState, levelDb: Float) {
        self.state = state
        self.levelDb = levelDb
    }

    func stop() {
        guard state.isActive else { return }
        state = .stopping
        sessionTask?.cancel()
        sessionTask = nil
        Task {
            await teardownStream()
            stopCapture()
            audioWarning = nil
            state = .idle
        }
    }

    // MARK: - Session lifecycle

    /// Connect, publish, then watch the connection; reconnect with backoff until
    /// cancelled via stop().
    private func runSession() async {
        do {
            try await startCaptureWithRetry()
        } catch {
            lastError = "Microphone unavailable: \(error.localizedDescription)"
            stopCapture()
            state = .idle
            return
        }

        var attempt = 0
        while !Task.isCancelled {
            do {
                try await connectAndPublish()
                attempt = 0
                state = .live(since: Date())
                try await watchConnection()
            } catch is CancellationError {
                break
            } catch {
                lastError = error.localizedDescription
            }
            if Task.isCancelled { break }

            await teardownStream()
            attempt += 1
            state = .reconnecting(attempt: attempt)
            // Exponential backoff, capped: 1s, 2s, 4s, 8s, then 10s forever.
            let delay = min(pow(2, Double(attempt - 1)), 10)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func connectAndPublish() async throws {
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        self.connection = connection
        self.stream = stream

        // StreamAudioConformer already hands the encoder 48 kHz; pinning it
        // here too keeps the AAC config stable if that ever changes.
        let audioSettings = AudioCodecSettings(
            bitRate: Config.audioBitrate,
            sampleRate: StreamAudioConformer.sampleRate
        )
        try await stream.setAudioSettings(audioSettings)

        _ = try await connection.connect(Config.rtmpURL)
        _ = try await stream.publish(streamKey)
    }

    /// Poll the connection until it drops; throwing hands control back to the
    /// reconnect loop. Also watches outgoing bytes: a publish with no audio
    /// sends only a few hundred bytes of handshake and metadata, while audio
    /// at the configured bitrate sends thousands per second.
    private func watchConnection() async throws {
        let publishedAt = Date()
        let startBytes = await stream?.info.byteCount ?? 0
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let connection else { throw URLError(.networkConnectionLost) }
            let connected = await connection.connected
            if !connected {
                throw URLError(.networkConnectionLost)
            }
            let elapsed = Date().timeIntervalSince(publishedAt)
            let sent = (await stream?.info.byteCount ?? 0) - startBytes
            // Expect at least a quarter of the nominal rate once the encoder
            // has had a few seconds to start.
            let expected = Double(Config.audioBitrate) / 8 * elapsed / 4
            if elapsed >= 6 {
                if Double(sent) < expected, audioWarning == nil {
                    Self.log.error("No audio reaching server: \(sent) bytes in \(Int(elapsed))s")
                }
                audioWarning = Double(sent) < expected
                    ? "Live, but no audio is reaching Evenings. Check the input and try going live again."
                    : nil
            }
        }
        throw CancellationError()
    }

    private func teardownStream() async {
        let stream = self.stream
        let connection = self.connection
        self.stream = nil
        self.connection = nil
        try? await stream?.close()
        try? await connection?.close()
    }

    // MARK: - Capture

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        // Prefer 48 kHz on the built-in hardware, but don't fight a USB
        // interface's fixed rate (Luna only does 96 kHz). An unsatisfiable
        // preference makes activation settle on the final rate in two steps,
        // and capture starting against the in-between rate is what crashed
        // when Luna was plugged in before launch.
        let hasUSBInput = (session.availableInputs ?? []).contains { $0.portType == .usbAudio }
        if !hasUSBInput {
            try session.setPreferredSampleRate(48_000)
        }
        // iOS silences all haptics while audio capture is active unless the
        // session opts in — without this, buttons on the stage feel dead.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        refreshInputs()
    }

    /// Configure the session and start capture, giving the route one chance
    /// to settle first. The first activation with a USB interface attached
    /// (plugged in before launch) can report a transitional format; rather
    /// than crash in installTap, startCapture throws and we go again.
    private func startCaptureWithRetry() async throws {
        do {
            try configureAudioSession()
            try startCapture()
        } catch {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try configureAudioSession()
            try startCapture()
        }
    }

    private func startCapture() throws {
        installObserversIfNeeded()
        // Already capturing (e.g. going live while monitoring) -- the tap stays.
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        if format.channelCount == 0 || abs(format.sampleRate - sessionRate) > 1 {
            // The engine caches the hardware format from when its I/O unit
            // last came up, and a USB interface with a fixed rate (Luna runs
            // at 96 kHz) can move the session's rate during activation.
            // Installing a tap with the stale format raises an uncatchable
            // CoreAudio exception instead of throwing; reset drops the cache.
            engine.reset()
            format = input.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0,
              abs(format.sampleRate - sessionRate) <= 1 else {
            throw CaptureError.inputNotReady
        }
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first
        Self.log.info("Capture: \(route?.portName ?? "unknown", privacy: .public) \(format, privacy: .public)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.bufferSink.send(buffer, when)
            let level = Self.rmsDb(buffer)
            // Convert here, on the audio thread: the result is a fresh buffer
            // that stays valid after the engine recycles the tap's.
            let converted = self.streamConformer.convert(buffer, when: when)
            Task { @MainActor in
                // Light smoothing so the meter doesn't flicker.
                self.levelDb = max(level, self.levelDb - 3)
                if let stream = self.stream, let (streamBuffer, streamTime) = converted {
                    await stream.append(streamBuffer, when: streamTime)
                }
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // Route changes (e.g. plugging/unplugging an interface) stop the
        // engine and can change the input format; restart the tap so capture
        // keeps flowing.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartCaptureAfterDisruption() }
        }

        // Keep the input list current as devices are plugged and unplugged.
        // Also the retry path for a capture start that failed mid-route-change
        // (startCapture throws on a half-configured route instead of
        // crashing): once the route lands somewhere final, try again.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInputs()
                self?.recoverCaptureIfStopped()
            }
        }

        // Interruptions (phone call, Siri): resume capture when they end.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in self?.restartCaptureAfterDisruption() }
        }
    }

    private func restartCaptureAfterDisruption() {
        let shouldRun = isMonitoring || captureHolds > 0 || state.isActive
        guard shouldRun else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try configureAudioSession()
            try startCapture()
        } catch {
            lastError = "Audio input interrupted: \(error.localizedDescription)"
        }
    }

    /// Capture should be running but the engine is down (a start attempt
    /// threw while the route was still settling): bring it back up.
    private func recoverCaptureIfStopped() {
        let shouldRun = isMonitoring || captureHolds > 0 || state.isActive
        guard shouldRun, !engine.isRunning else { return }
        do {
            try configureAudioSession()
            try startCapture()
        } catch {
            lastError = "Audio input interrupted: \(error.localizedDescription)"
        }
    }

    private func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        levelDb = -160
    }

    private static let log = Logger(subsystem: "co.evenings.EveningsBroadcaster", category: "broadcast")

    private nonisolated static func rmsDb(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let frameCount = vDSP_Length(buffer.frameLength)
        var meanSquare: Float = 0
        var total: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            vDSP_measqv(channels[channel], 1, &meanSquare, frameCount)
            total += meanSquare
        }
        return 10 * log10(max(total / Float(channelCount), 1e-12))
    }
}
