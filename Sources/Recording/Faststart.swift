import AVFoundation
import Foundation

/// AVAudioFile writes .m4a with the moov atom (duration metadata) at the end
/// of the file. The API server computes duration by streaming the S3 object
/// through a forward-only parser, which never reaches a trailing moov — the
/// track lands with duration 0. Remuxing with shouldOptimizeForNetworkUse
/// moves moov to the front (faststart): the server reads the duration, and
/// web playback starts without downloading the whole file. Passthrough
/// preset = no re-encode, so this takes seconds even for long recordings.
enum Faststart {
    static func makeStreamable(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("faststart-\(UUID().uuidString).m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
        return output
    }
}
