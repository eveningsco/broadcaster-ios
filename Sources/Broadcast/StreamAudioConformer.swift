import AVFAudio
import Foundation

/// Converts capture buffers into the one shape HaishinKit's AAC encoder
/// handles reliably: 48 kHz, Float32, non-interleaved, mono or stereo.
///
/// HaishinKit builds its encoder from whatever format it's handed and fails
/// silently when that format is unusual: a 96 kHz interface, an input with
/// more than two channels (no AAC layout, so no converter), or a layout the
/// encoder rejects. Publish still succeeds and the app shows Live, but no
/// audio packet (not even the AAC sequence header) reaches the server, and
/// the empty recording is discarded. Recording works from the same inputs
/// because AACBufferWriter converts explicitly; this does the same for the
/// stream.
///
/// Called only from the capture tap on the audio thread. Each call returns a
/// freshly allocated buffer, so the result can safely cross to another actor
/// after the tap's own buffer is recycled.
final class StreamAudioConformer: @unchecked Sendable {
    static let sampleRate: Double = 48_000

    private var converter: AVAudioConverter?
    /// Position of the next output frame, in 48 kHz frames. HaishinKit derives
    /// gaps from sampleTime, so it has to count in the rate we hand it rather
    /// than the tap's (which can be 96 kHz).
    private var outputSampleTime: AVAudioFramePosition = 0

    func convert(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) -> (AVAudioPCMBuffer, AVAudioTime)? {
        guard buffer.frameLength > 0, let converter = converter(for: buffer.format) else { return nil }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var pending: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if let next = pending {
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        // A rate converter can hold back the first few frames; nothing to send yet.
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }

        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let time = AVAudioTime(hostTime: hostTime, sampleTime: outputSampleTime, atRate: Self.sampleRate)
        outputSampleTime += AVAudioFramePosition(output.frameLength)
        return (output, time)
    }

    private func converter(for input: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converter.inputFormat == input {
            return converter
        }
        // More than two channels (multi-input interfaces) carry no layout the
        // encoder understands; stream the first pair, which is what the
        // interface's main inputs map to.
        let channels: AVAudioChannelCount = min(input.channelCount, 2)
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: channels,
                interleaved: false
            ),
            let newConverter = AVAudioConverter(from: input, to: output)
        else {
            converter = nil
            return nil
        }
        if input.channelCount > 2 {
            newConverter.channelMap = [0, 1]
        }
        converter = newConverter
        return newConverter
    }
}
