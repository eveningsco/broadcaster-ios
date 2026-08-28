import AVFAudio
import Foundation

/// Writes PCM buffers to an AAC .m4a file, converting when the source runs
/// faster than the encoder allows. Apple's AAC codec tops out at 48 kHz;
/// asking for more (e.g. Luna's fixed 96 kHz USB input) makes every
/// AVAudioFile write throw paramErr (-50). All callers that encode AAC from
/// a live or file-derived format should go through this.
final class AACBufferWriter: @unchecked Sendable {
    enum WriteError: Error {
        case converterUnavailable
        case bufferAllocationFailed
        case conversionFailed
    }

    static let maxSampleRate: Double = 48_000

    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    // write() runs on the audio thread while finish() comes from the main
    // actor at stop; serialize access to the converter and file.
    private let lock = NSLock()

    /// Creates the .m4a at `url` for material arriving in `source`. The file
    /// is finalized when the writer is released, after `finish()`.
    init(url: URL, source: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(source.sampleRate, Self.maxSampleRate),
            AVNumberOfChannelsKey: source.channelCount,
            AVEncoderBitRateKey: Config.audioBitrate,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: source.commonFormat,
            interleaved: source.isInterleaved
        )
        if file.processingFormat == source {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: file.processingFormat) else {
                throw WriteError.converterUnavailable
            }
            self.converter = converter
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let converter else {
            try file.write(from: buffer)
            return
        }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity
        ) else {
            throw WriteError.bufferAllocationFailed
        }

        var pending: AVAudioPCMBuffer? = buffer
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if let next = pending {
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw WriteError.conversionFailed }
        if converted.frameLength > 0 {
            try file.write(from: converted)
        }
    }

    /// Drains the converter's internal latency (a rate converter holds back a
    /// handful of frames). Call once when no more input is coming; the file
    /// itself finalizes when the writer is released.
    func finish() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let converter else { return }
        while true {
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: 4096
            ) else {
                throw WriteError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw WriteError.conversionFailed }
            if converted.frameLength > 0 {
                try file.write(from: converted)
            }
            if status == .endOfStream || converted.frameLength == 0 { break }
        }
    }
}
