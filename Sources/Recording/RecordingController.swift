import AVFAudio
import Foundation

enum RecordingState: Equatable {
    case idle
    case recording(since: Date)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Offline recording: writes the capture tap's buffers to an AAC .m4a file in
/// Documents/recordings. No network involved until the upload step.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var lastError: String?

    private let broadcast: BroadcastController
    private var file: AVAudioFile?
    private var fileURL: URL?

    static let recordingsDirectory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("recordings", isDirectory: true)
    }()

    init(broadcast: BroadcastController) {
        self.broadcast = broadcast
    }

    func start() {
        guard state == .idle, !broadcast.state.isActive else { return }
        lastError = nil

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, granted, self.state == .idle else { return }
                self.beginRecording()
            }
        }
    }

    /// Stops and returns the finished file, or nil if nothing was recording.
    func stop() -> URL? {
        guard state.isRecording else { return nil }

        // Detach the sink first; the last in-flight write finishes before the
        // file reference is released (AVAudioFile finalizes on dealloc).
        broadcast.bufferSink.set(nil)
        file = nil
        broadcast.releaseCapture()
        state = .idle

        let url = fileURL
        fileURL = nil
        return url
    }

    private func beginRecording() {
        do {
            try FileManager.default.createDirectory(
                at: Self.recordingsDirectory,
                withIntermediateDirectories: true
            )
            try broadcast.retainCapture()

            let format = broadcast.captureFormat
            let url = Self.recordingsDirectory
                .appendingPathComponent("\(Self.defaultTitle(for: Date())).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: Config.audioBitrate,
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )

            self.file = file
            self.fileURL = url

            broadcast.bufferSink.set { [weak self] buffer, _ in
                // Audio thread. A format change (route switch mid-recording)
                // can't be written to this file — end the recording honestly
                // instead of writing garbage.
                guard buffer.format == file.processingFormat else {
                    Task { @MainActor in self?.endForFormatChange() }
                    return
                }
                do {
                    try file.write(from: buffer)
                } catch {
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
            }

            state = .recording(since: Date())
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            broadcast.bufferSink.set(nil)
            file = nil
            fileURL = nil
        }
    }

    private func endForFormatChange() {
        guard state.isRecording else { return }
        lastError = "Audio input changed — recording saved up to that point."
        onAutoStopped?(stop())
    }

    /// Set by the owner; receives the file when a recording ends on its own
    /// (input format change) so it can enter the normal upload flow.
    var onAutoStopped: ((URL?) -> Void)?

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        // "." instead of ":" — this becomes a filename.
        formatter.dateFormat = "MMM d, h.mm a"
        return "Recording \(formatter.string(from: date))"
    }
}
