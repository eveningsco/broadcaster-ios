import SwiftUI
import UIKit

/// Soft tap for the transport controls, matching row selection.
private enum TrackDetailHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
}

/// The track detail sheet, opened by tapping a track's cover in the Library
/// or Explore list: the title and byline, the cover at full width, the
/// description, a waveform scrubber with an elapsed/total readout, and a
/// transport (−15 s, play/pause, +15 s). Along the bottom sit a share pill
/// (system share sheet with the track's evenings.fm page) and a loop toggle
/// on the left, and the Edit pill on the right, which opens the combined
/// audio editor (`AudioEditSheet`). Owners can also edit the title and
/// description from the toolbar menu.
///
/// Playback goes through the shared `TrackPlayer`, so the home mini player,
/// the lock screen and this sheet all show the same position; the sheet
/// doesn't own any audio of its own.
struct TrackDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Snapshot from the list; display reads the live copy (`current`) so a
    /// title edit shows up without reopening.
    let track: LibraryTrack
    @ObservedObject var player: TrackPlayer

    @StateObject private var waveform = WaveformLoader()
    @State private var isScrubbing = false
    @State private var editingAudio = false
    @State private var editingDetails = false

    /// Screenshot mode's `track` scene: nothing is loaded (no network), so
    /// the scrubber, readout and play state pose from fixtures.
    private var isFixture: Bool { ScreenshotMode.isActive }

    private var current: LibraryTrack {
        model.library.first { $0.id == track.id }
            ?? model.exploreTracks.first { $0.id == track.id }
            ?? track
    }

    private var key: String { TrackPlayer.key(for: track) }
    /// This track is the one in the player (playing or paused).
    private var isLoaded: Bool { isFixture || player.playingKey == key }
    private var isPlaying: Bool { isFixture || (isLoaded && !player.isPaused) }
    private var progress: Double {
        if isFixture { return ScreenshotFixtures.editPlayhead }
        return isLoaded ? player.progress : 0
    }
    private var levels: [Float]? {
        waveform.levels ?? (isFixture ? ScreenshotFixtures.editWaveform : nil)
    }
    private var totalDuration: TimeInterval { TimeInterval(current.duration ?? 0) }
    private var elapsed: TimeInterval { progress * totalDuration }

    /// The mic owns the audio session while broadcasting, same rule as the
    /// list rows and the editor.
    private var playbackBlocked: Bool { model.broadcast.state.isActive }

    private var coverURL: URL? {
        (current.image ?? current.station?.image).flatMap(URL.init(string:))
    }

    private var byline: String {
        var parts: [String] = []
        if let station = current.station?.name {
            parts.append(station)
        }
        if let date = current.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private var footnote: String {
        var parts: [String] = []
        if totalDuration > 0 {
            let total = Int(totalDuration)
            let h = total / 3600
            let m = (total % 3600) / 60
            parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
        }
        if let listens = current.listens, listens > 0 {
            parts.append("\(listens) listen\(listens == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var description: String? {
        let text = (current.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    heading

                    TrackArtwork(url: coverURL, symbolFont: .system(size: 56))
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 300)
                        // Square with continuous rounded corners: the row's
                        // 8pt-on-48pt proportion, scaled up (never a circle).
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    if let description {
                        Text(description)
                            .font(.social(.subheadline))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    scrubber

                    transport
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .navigationTitle("Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if current.owner == true {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button {
                                editingDetails = true
                            } label: {
                                Label("Edit Details", systemImage: "pencil")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !isFixture else { return }
                waveform.load(key: key, url: current.audioURL, buckets: 48)
            }
            .sheet(isPresented: $editingAudio) {
                AudioEditSheet(track: current)
            }
            .sheet(isPresented: $editingDetails) {
                EditTrackSheet(track: current)
            }
        }
        .presentationDragIndicator(.visible)
        .modifier(OpaqueSheetBackground())
    }

    private var heading: some View {
        VStack(spacing: 6) {
            Text(current.title ?? "Untitled")
                .font(.custom("ETBembo-SemiBoldOSF", size: 30, relativeTo: .title))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            if !byline.isEmpty {
                Text(byline)
                    .font(.social(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.social(.footnote))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The real waveform doubling as a scrubber (flat bars until the levels
    /// have decoded), with elapsed / total underneath.
    private var scrubber: some View {
        VStack(spacing: 12) {
            PlayingWaveform(
                levels: levels,
                progress: progress,
                onScrub: { fraction in
                    guard !playbackBlocked else { return }
                    if isLoaded {
                        player.seek(toFraction: fraction)
                    } else {
                        // Not loaded yet: a scrub just starts the track;
                        // the seek has nowhere to land before metadata.
                        player.toggle(track)
                    }
                },
                isScrubbing: $isScrubbing
            )
            .frame(height: 44)

            Text("\(AudioEditSheet.format(elapsed)) / \(AudioEditSheet.format(totalDuration))")
                .font(.social(.footnote))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            transportButton("gobackward.15", label: "Back 15 seconds") {
                player.skip(by: -15)
            }
            .disabled(!isLoaded)
            .opacity(isLoaded ? 1 : 0.4)
            Spacer(minLength: 0)
            Button {
                TrackDetailHaptics.tap.impactOccurred()
                player.toggle(track)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .medium))
                    .frame(width: 72, height: 72)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Spacer(minLength: 0)
            transportButton("goforward.15", label: "Forward 15 seconds") {
                player.skip(by: 15)
            }
            .disabled(!isLoaded)
            .opacity(isLoaded ? 1 : 0.4)
            Spacer(minLength: 0)
        }
        .disabled(playbackBlocked)
        .opacity(playbackBlocked ? 0.4 : 1)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            TrackDetailHaptics.tap.impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Share + loop in one pill on the left, Edit on the right.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                if let url = current.webURL {
                    ShareLink(item: url, subject: Text(current.title ?? "Untitled")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .frame(width: 56, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share link")
                }
                Button {
                    TrackDetailHaptics.tap.impactOccurred()
                    player.toggleLooping()
                } label: {
                    Image(systemName: "repeat")
                        .font(.title3)
                        .foregroundStyle(player.isLoopingCurrent && isLoaded ? Color.eveningsRed : .primary)
                        .frame(width: 56, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isLoaded)
                .opacity(isLoaded ? 1 : 0.4)
                .accessibilityLabel("Loop")
            }
            .padding(.horizontal, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))

            Spacer(minLength: 0)

            if current.audioURL != nil {
                Button {
                    TrackDetailHaptics.tap.impactOccurred()
                    editingAudio = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.social(.body, weight: .bold))
                        .padding(.horizontal, 24)
                        .frame(height: 52)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playbackBlocked)
                .opacity(playbackBlocked ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Color(.secondarySystemBackground))
    }
}
