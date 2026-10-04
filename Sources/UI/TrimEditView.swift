import AVFoundation
import SwiftUI
import UIKit

/// Tap for transport, ticks while dragging handles, and a confirmation
/// buzz when the trimmed version lands.
enum TrimHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let grab = UIImpactFeedbackGenerator(style: .medium)
    static let tick = UISelectionFeedbackGenerator()
    static let confirm = UINotificationFeedbackGenerator()
}

/// Decodes the preview's growing download into per-bucket levels on a
/// polling timer, so the real waveform fills in left to right off the one
/// stream. Each pass reads only newly-arrived frames (carry-over state),
/// keeping total work linear.
@MainActor
final class IncrementalWaveform: ObservableObject {
    @Published private(set) var levels: [Float]?

    private var timer: Timer?
    private var busy = false
    private var state = DecodeState(buckets: 56)
    private var fileURL: URL?
    private var durationHint: TimeInterval = 0
    private var isComplete: (() -> Bool)?

    func begin(fileURL: URL, duration: TimeInterval, isComplete: @escaping () -> Bool) {
        guard timer == nil else { return }
        self.fileURL = fileURL
        durationHint = duration
        self.isComplete = isComplete
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pass()
            }
        }
        // First pass right away rather than 1.5s from now.
        pass()
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
    }

    private func pass() {
        guard !busy, let fileURL else { return }
        busy = true
        let wasComplete = isComplete?() ?? false
        var carried = state
        let hint = durationHint
        Task.detached(priority: .utility) { [weak self] in
            let levels = Self.decodeMore(from: fileURL, state: &carried, totalDurationHint: hint)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.state = carried
                if let levels {
                    self.levels = levels
                }
                self.busy = false
                // The pass that ran after completion has read every frame.
                if wasComplete {
                    self.teardown()
                }
            }
        }
    }

    private struct DecodeState {
        var sums: [Double]
        var counts: [Int]
        var nextFrame: AVAudioFramePosition = 0
        var framesPerBucket: AVAudioFramePosition = 0
        var buckets: Int

        init(buckets: Int) {
            self.buckets = buckets
            sums = [Double](repeating: 0, count: buckets)
            counts = [Int](repeating: 0, count: buckets)
        }
    }

    /// Reads whatever new audio is on disk into the running per-bucket RMS.
    /// Reads past the truncation point end the pass; the next one resumes
    /// at the same frame.
    private nonisolated static func decodeMore(
        from url: URL,
        state: inout DecodeState,
        totalDurationHint: Double
    ) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        if state.framesPerBucket == 0 {
            // A partial file underreports its length; the bucket grid must
            // span the full track, so prefer the known duration.
            let hinted = AVAudioFramePosition(totalDurationHint * format.sampleRate)
            let total = max(hinted, file.length)
            guard total > 0 else { return nil }
            state.framesPerBucket = max(1, total / AVAudioFramePosition(state.buckets))
        }
        let channels = Int(format.channelCount)
        guard channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 17) else {
            return nil
        }
        file.framePosition = state.nextFrame
        let sampleStride = 16

        while true {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var i = (sampleStride - Int(state.nextFrame) % sampleStride) % sampleStride
            while i < frameCount {
                let globalFrame = state.nextFrame + AVAudioFramePosition(i)
                let bucket = min(state.buckets - 1, Int(globalFrame / state.framesPerBucket))
                var sample: Float = 0
                for channel in 0..<channels {
                    sample += data[channel][i] * data[channel][i]
                }
                state.sums[bucket] += Double(sample) / Double(channels)
                state.counts[bucket] += 1
                i += sampleStride
            }
            state.nextFrame += AVAudioFramePosition(frameCount)
        }

        let rms = zip(state.sums, state.counts).map { sum, count in
            count > 0 ? sqrt(sum / Double(count)) : 0
        }
        guard let peak = rms.max(), peak > 0 else { return nil }
        return rms.map { Float(pow($0 / peak, 0.7)) }
    }
}

/// Copies the selected frame range of the source into a fresh AAC file —
/// no processing graph, just a read-write loop, so it runs far faster than
/// real time.
enum TrimRenderer {
    enum RenderError: Error {
        case emptySelection
    }

    static func render(
        source: URL,
        startFraction: Double,
        endFraction: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: source)
            let total = file.length
            let startFrame = AVAudioFramePosition((Double(total) * startFraction).rounded())
            let endFrame = AVAudioFramePosition((Double(total) * endFraction).rounded())
            guard endFrame > startFrame else {
                throw RenderError.emptySelection
            }
            let format = file.processingFormat

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("trim-render-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let output = try AACBufferWriter(url: destination, source: format)
            let capacity: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw RenderError.emptySelection
            }

            file.framePosition = startFrame
            let totalOut = endFrame - startFrame
            var remaining = totalOut
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
                try file.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 { break }
                try output.write(buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
                onProgress(1 - Double(remaining) / Double(totalOut))
            }
            try output.finish()
            return destination
        }.value
    }
}

/// The Voice Memos-style trim strip: the whole track in a rounded housing,
/// white in/out handles, and a yellow playhead riding the looping audition.
/// One drag gesture serves all three — whichever target is nearest at
/// touch-down wins, handles taking priority within their grab zone.
struct TrimStrip: View {
    @Binding var start: Double
    @Binding var end: Double
    /// Playhead position as a fraction of the whole track.
    let progress: Double
    let levels: [Float]?
    /// Smallest allowed selection, as a fraction.
    let minGap: Double
    /// Finger touched down / is moving on the playhead — drives the
    /// audible scrub (optional; without them the strip only seeks on
    /// release).
    var onScrubBegin: (() -> Void)?
    var onScrubMove: ((Double) -> Void)?
    /// Playhead released after a scrub.
    let onScrub: (Double) -> Void
    /// A handle finished moving.
    let onHandleMoved: () -> Void

    private enum Target {
        case start
        case end
        case playhead
    }

    @State private var active: Target?
    @State private var scrubPreview: Double?
    @State private var lastTickedStep: Int?

    private var barCount: Int { levels?.count ?? 56 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let displayedProgress = min(max(scrubPreview ?? progress, start), end)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                bars(width: width, height: height)

                // In/out handles.
                handle(height: height)
                    .position(x: max(6, start * width), y: height / 2)
                handle(height: height)
                    .position(x: min(width - 6, end * width), y: height / 2)

                // Playhead, only meaningful inside the selection.
                Capsule()
                    .fill(Color.yellow)
                    .frame(width: 4, height: height - 28)
                    .position(x: displayedProgress * width, y: height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if active == nil {
                            active = target(at: gesture.startLocation.x, width: width)
                            TrimHaptics.grab.impactOccurred(intensity: 0.7)
                            TrimHaptics.tick.prepare()
                            lastTickedStep = nil
                            if active == .playhead {
                                onScrubBegin?()
                            }
                        }
                        let fraction = min(max(gesture.location.x / width, 0), 1)
                        switch active {
                        case .start:
                            start = min(fraction, end - minGap)
                            tickIfNeeded(fraction: start)
                        case .end:
                            end = max(fraction, start + minGap)
                            tickIfNeeded(fraction: end)
                        case .playhead:
                            // The playhead can't leave the selection; the
                            // audible scrub follows the clamped position.
                            let clamped = min(max(fraction, start), end)
                            scrubPreview = clamped
                            onScrubMove?(clamped)
                        case nil:
                            break
                        }
                    }
                    .onEnded { gesture in
                        switch active {
                        case .start, .end:
                            onHandleMoved()
                        case .playhead:
                            // Always paired with onScrubBegin, or the
                            // preview would stay in its scrub state.
                            let fraction = min(max(gesture.location.x / width, 0), 1)
                            onScrub(scrubPreview ?? min(max(fraction, start), end))
                        case nil:
                            break
                        }
                        scrubPreview = nil
                        active = nil
                        lastTickedStep = nil
                    }
            )
        }
    }

    /// Handles win within their grab zone (nearer one on overlap);
    /// anywhere else moves the playhead.
    private func target(at x: CGFloat, width: CGFloat) -> Target {
        let startDistance = abs(x - start * width)
        let endDistance = abs(x - end * width)
        let grabZone: CGFloat = 32
        if min(startDistance, endDistance) <= grabZone {
            return startDistance <= endDistance ? .start : .end
        }
        return .playhead
    }

    /// A selection tick each 0.5% of travel, so dragging a handle feels
    /// ratcheted like the tempo wheel.
    private func tickIfNeeded(fraction: Double) {
        let step = Int(fraction * 200)
        if step != lastTickedStep {
            if lastTickedStep != nil {
                TrimHaptics.tick.selectionChanged()
                TrimHaptics.tick.prepare()
            }
            lastTickedStep = step
        }
    }

    private func handle(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 5, height: height - 20)
            .shadow(color: .black.opacity(0.35), radius: 2)
    }

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<barCount, id: \.self) { index in
                let barFraction = (Double(index) + 0.5) / Double(barCount)
                let inSelection = barFraction >= start && barFraction <= end
                Capsule()
                    .fill(.primary)
                    .frame(
                        width: 2.5,
                        height: levels.map { max(6, (height - 44) * CGFloat($0[index])) } ?? 8
                    )
                    .frame(maxWidth: .infinity)
                    .opacity(inSelection ? 0.9 : 0.25)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.25), value: levels)
    }
}
