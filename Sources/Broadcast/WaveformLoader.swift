import AVFoundation
import Foundation

/// Computes a coarse amplitude waveform (per-bucket RMS, normalized 0...1)
/// for a track so the mini player can draw the real audio. Remote tracks are
/// downloaded to a temp file first; results are cached in memory by key.
@MainActor
final class WaveformLoader: ObservableObject {
    @Published private(set) var levels: [Float]?

    private var cache: [String: [Float]] = [:]
    private var currentKey: String?
    private var task: Task<Void, Never>?

    func load(key: String, url: URL?, buckets: Int = 24) {
        guard currentKey != key else { return }
        currentKey = key
        task?.cancel()
        if let cached = cache[key] {
            levels = cached
            return
        }
        levels = nil
        guard let url else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            guard let computed = try? await Self.computeLevels(for: url, buckets: buckets),
                  !computed.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache[key] = computed
                if self.currentKey == key {
                    self.levels = computed
                }
            }
        }
    }

    /// Decodes the file (downloading first when remote) and reduces it to
    /// normalized per-bucket RMS levels. Samples are strided for speed; the
    /// result is shaped with a power curve so quiet passages stay visible.
    private nonisolated static func computeLevels(for url: URL, buckets: Int) async throws -> [Float] {
        let localURL: URL
        var temporary = false
        if url.isFileURL {
            localURL = url
        } else {
            let (downloaded, _) = try await URLSession.shared.download(from: url)
            // Keep the original extension so the decoder recognizes the format.
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let renamed = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.moveItem(at: downloaded, to: renamed)
            localURL = renamed
            temporary = true
        }
        defer {
            if temporary {
                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let file = try AVAudioFile(forReading: localURL)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, buckets > 0 else { return [] }
        let framesPerBucket = max(1, totalFrames / buckets)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 18) else {
            return []
        }

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var frameIndex = 0
        let sampleStride = 16

        while true {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var i = (sampleStride - frameIndex % sampleStride) % sampleStride
            while i < frameCount {
                let bucket = min(buckets - 1, (frameIndex + i) / framesPerBucket)
                var sample: Float = 0
                for channel in 0..<channels {
                    sample += data[channel][i] * data[channel][i]
                }
                sums[bucket] += Double(sample) / Double(channels)
                counts[bucket] += 1
                i += sampleStride
            }
            frameIndex += frameCount
        }

        let rms = zip(sums, counts).map { sum, count in
            count > 0 ? sqrt(sum / Double(count)) : 0
        }
        guard let peak = rms.max(), peak > 0 else { return [] }
        return rms.map { Float(pow($0 / peak, 0.7)) }
    }
}
