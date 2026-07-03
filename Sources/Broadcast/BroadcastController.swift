import AVFAudio
import Accelerate
import Foundation
import HaishinKit
import RTMPHaishinKit

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

    private let engine = AVAudioEngine()
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var sessionTask: Task<Void, Never>?
    private var streamKey = ""
    private var isMonitoring = false

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
        stopCapture()
        isMonitoring = false
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
        try session.setActive(true)
    }

    private func startCapture() throws {
        // Already capturing (e.g. going live while monitoring) -- the tap stays.
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
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
