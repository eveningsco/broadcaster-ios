import AVFAudio
import Accelerate
import Foundation
import HaishinKit
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
/// The media server has zero reconnect tolerance today: every TCP drop ends the
/// server-side session (finalizing a recording), and a half-open socket can make
/// re-publishes fail with "already publishing" until the server reaps it. So the
/// client keeps retrying with backoff until the key frees up.
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
                    try self.configureAudioSession()
                    try self.startCapture()
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
        state = .connecting

        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() {
        guard state.isActive else { return }
        state = .stopping
        sessionTask?.cancel()
        sessionTask = nil
        Task {
            await teardownStream()
            stopCapture()
            state = .idle
        }
    }

    // MARK: - Session lifecycle

    /// Connect, publish, then watch the connection; reconnect with backoff until
    /// cancelled via stop().
    private func runSession() async {
        do {
            try configureAudioSession()
            try startCapture()
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

        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = Config.audioBitrate
        try await stream.setAudioSettings(audioSettings)

        _ = try await connection.connect(Config.rtmpURL)
        _ = try await stream.publish(streamKey)
    }

    /// Poll the connection until it drops; throwing hands control back to the
    /// reconnect loop.
    private func watchConnection() async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let connection else { throw URLError(.networkConnectionLost) }
            let connected = await connection.connected
            if !connected {
                throw URLError(.networkConnectionLost)
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
        try session.setPreferredSampleRate(48_000)
        // iOS silences all haptics while audio capture is active unless the
        // session opts in — without this, buttons on the stage feel dead.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        refreshInputs()
    }

    private func startCapture() throws {
        installObserversIfNeeded()
        // Already capturing (e.g. going live while monitoring) -- the tap stays.
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.bufferSink.send(buffer, when)
            let level = Self.rmsDb(buffer)
            Task { @MainActor in
                // Light smoothing so the meter doesn't flicker.
                self.levelDb = max(level, self.levelDb - 3)
                if let stream = self.stream {
                    await stream.append(buffer, when: when)
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
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshInputs() }
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

    private func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        levelDb = -160
    }

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
