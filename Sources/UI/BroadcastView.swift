import SwiftUI

struct BroadcastView: View {
    enum StageMode: String, CaseIterable {
        case live = "Live"
        case record = "Record"
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var broadcast: BroadcastController
    @ObservedObject var recorder: RecordingController
    @ObservedObject var uploads: UploadManager
    var title = "Go Live"
    @State private var mode: StageMode = .live
    @State private var listeners: Int?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isBusy: Bool {
        broadcast.state.isActive || recorder.state.isRecording
    }

    var body: some View {
        VStack(spacing: 32) {
            header

            Picker("", selection: $mode) {
                ForEach(StageMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .disabled(isBusy)

            statusBadge

            if case .live(let since) = broadcast.state {
                Text(elapsed(since: since))
                    .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                if let listeners {
                    Label("\(listeners) listening", systemImage: "ear")
                        .foregroundStyle(.secondary)
                }
            } else if case .recording(let since) = recorder.state {
                Text(elapsed(since: since))
                    .font(.system(.largeTitle, design: .monospaced).weight(.medium))
            }

            RadialLevelMeter(levelDb: broadcast.levelDb)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 24)
                .overlay {
                    Button(action: primaryAction) {
                        Text(centerLabel)
                            .font(.title.weight(.semibold))
                            .foregroundStyle(centerColor)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: centerLabel)
                            // A generous tap target inside the ring.
                            .frame(width: 160, height: 160)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(centerDisabled)
                }

            if uploads.uploadingDraftId != nil {
                VStack(spacing: 6) {
                    ProgressView(value: uploads.uploadProgress)
                    Text("Saving to your library…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            } else if let uploadError = uploads.uploadError, mode == .record {
                Text("Saved on this phone — upload from the library when you're back online. (\(uploadError))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let error = broadcast.lastError, case .reconnecting = broadcast.state {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let recorderError = recorder.lastError, mode == .record {
                Text(recorderError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            Spacer()
        }
        .padding(24)
        .onReceive(ticker) { date in
            now = date
        }
        .task(id: broadcast.state.isActive) {
            guard broadcast.state.isActive else {
                listeners = nil
                return
            }
            while !Task.isCancelled {
                if let status = await model.fetchStatus() {
                    listeners = status.listeners
                }
                try? await Task.sleep(nanoseconds: UInt64(Config.statusPollInterval * 1_000_000_000))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: title)
                if let slug = model.credentials?.station?.slug {
                    Text("evenings.fm/\(slug)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if recorder.state.isRecording {
            Label("RECORDING", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
        } else {
            broadcastBadge
        }
    }

    @ViewBuilder
    private var broadcastBadge: some View {
        switch broadcast.state {
        case .idle:
            Label(mode == .record ? "Ready to record" : "Offline", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
        case .live:
            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.red)
        case .reconnecting(let attempt):
            Label("Reconnecting (attempt \(attempt))…", systemImage: "arrow.clockwise")
                .foregroundStyle(.orange)
        case .stopping:
            Label("Stopping…", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var centerLabel: String {
        if mode == .record {
            return recorder.state.isRecording ? "Stop" : "Record"
        }
        switch broadcast.state {
        case .idle: return "Go Live"
        case .connecting: return "Connecting…"
        case .live: return "End"
        case .reconnecting: return "Reconnecting…"
        case .stopping: return "Stopping…"
        }
    }

    private var centerColor: Color {
        if mode == .record {
            return recorder.state.isRecording ? .primary : .red
        }
        switch broadcast.state {
        case .idle: return .red
        case .live: return .primary
        case .connecting, .reconnecting: return .orange
        case .stopping: return .secondary
        }
    }

    private var centerDisabled: Bool {
        if mode == .record {
            return broadcast.state.isActive
        }
        return broadcast.state == .stopping
    }

    private func primaryAction() {
        if mode == .record {
            if recorder.state.isRecording {
                if let url = recorder.stop() {
                    model.handleFinishedRecording(url)
                }
            } else {
                model.player.stop()
                recorder.start()
            }
        } else if broadcast.state.isActive {
            broadcast.stop()
        } else {
            Task {
                model.player.stop()
                await model.ensureFreshSession()
                guard let key = model.credentials?.streamKey else { return }
                broadcast.start(streamKey: key)
            }
        }
    }

    private func elapsed(since: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// RMS meter as a ring of dots (-60 dB to 0 dB): dots light clockwise from
/// the top as the level rises, with green/yellow/red zones and a decaying
/// peak-hold dot.
struct RadialLevelMeter: View {
    let levelDb: Float
    @State private var peak: CGFloat = 0

    private let segmentCount = 24
    private let dotSize: CGFloat = 12

    var body: some View {
        let fraction = CGFloat(max(0, min(1, (levelDb + 60) / 60)))
        let peakIndex = peak > 0.02 ? Int((peak * CGFloat(segmentCount)).rounded()) - 1 : -1

        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2 - dotSize / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let threshold = CGFloat(index + 1) / CGFloat(segmentCount)
                    // Start at 12 o'clock, fill clockwise.
                    let angle = (Double(index) / Double(segmentCount)) * 2 * .pi - .pi / 2
                    Circle()
                        .fill(dotColor(
                            threshold: threshold,
                            lit: fraction >= threshold,
                            isPeak: index == peakIndex
                        ))
                        .frame(width: dotSize, height: dotSize)
                        .position(
                            x: center.x + radius * CGFloat(cos(angle)),
                            y: center.y + radius * CGFloat(sin(angle))
                        )
                }
            }
        }
        .onChange(of: fraction) { newValue in
            if newValue > peak {
                peak = newValue
            }
        }
        .task {
            // Let the peak dot fall slowly back down.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                peak = max(0, peak - 0.008)
            }
        }
    }

    private func dotColor(threshold: CGFloat, lit: Bool, isPeak: Bool) -> Color {
        if lit {
            if threshold > 0.9 { return .red }
            if threshold > 0.72 { return .yellow }
            return .green
        }
        if isPeak {
            return Color.primary.opacity(0.5)
        }
        return Color.primary.opacity(0.12)
    }
}
