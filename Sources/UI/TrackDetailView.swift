import SwiftUI
import UIKit

/// Soft tap for the transport controls, matching row selection.
private enum TrackDetailHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let snap = UIImpactFeedbackGenerator(style: .medium)
}

/// Which track the detail card is showing, and which list cover it grew
/// out of. The hero id names the list too (`library-cover-12`,
/// `explore-cover-12`) so a track present in both lists has exactly one
/// matched-geometry source.
struct TrackDetailSelection: Equatable {
    let track: LibraryTrack
    let heroID: String

    static func heroID(list: String, track: LibraryTrack) -> String {
        "\(list)-cover-\(track.id)"
    }
}

/// The track detail card, opened by tapping a track's cover in the Library
/// or Explore list. Not a sheet: the 48pt artwork lifts out of its row and
/// grows into the card's cover (`matchedGeometryEffect` on `HomeView`'s
/// namespace) while the card's chrome fades in around it and the home
/// layer dims and scales back behind.
///
/// The card floats inset from the screen edges, bottom-anchored: title and
/// byline, the cover, the description, a waveform scrubber with
/// elapsed/total, and a transport (−15 s, play/pause, +15 s). Two pills
/// float under it: share + loop on the left, Edit on the right, which opens
/// the combined audio editor (`AudioEditSheet`). Owners get Edit Details
/// from a `…` in the card's corner.
///
/// Dismiss by dragging the card down (tracks the finger, rubber-banded
/// upwards; release with momentum and the cover flies back into its row) or
/// by tapping the backdrop.
///
/// Playback goes through the shared `TrackPlayer`, so the home mini player,
/// the lock screen and this card all show the same position.
struct TrackDetailOverlay: View {
    @EnvironmentObject private var model: AppModel
    let selection: TrackDetailSelection
    @ObservedObject var player: TrackPlayer
    let heroNamespace: Namespace.ID
    /// True once the cover has flown out of its row. Owned by `HomeView` so
    /// the row knows to hide its copy; flipped back on dismiss, and the row
    /// becomes the matched-geometry source again.
    @Binding var expanded: Bool
    let safeArea: EdgeInsets
    /// Called once the fly-back animation has finished; removes the overlay.
    let onDismiss: () -> Void

    @StateObject private var waveform = WaveformLoader()
    @State private var isScrubbing = false
    @State private var editingAudio = false
    @State private var editingDetails = false
    /// Vertical card displacement while dragging to dismiss.
    @State private var dragOffset: CGFloat = 0
    @State private var dismissing = false

    private var track: LibraryTrack { selection.track }

    /// Screenshot mode's `track` scene: nothing is loaded (no network), so
    /// the scrubber, readout and play state pose from fixtures.
    private var isFixture: Bool { ScreenshotMode.isActive }

    /// Display reads the live copy so a title edit shows up immediately.
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

    /// The card's surface; the pills share it so they read as one set.
    private let surface = Color(.tertiarySystemBackground)
    private let cardCorner: CGFloat = 40

    /// How far along the drag-to-dismiss is (0 at rest, 1 at the commit
    /// distance); thins the backdrop as the card goes.
    private var dragProgress: CGFloat {
        min(max(dragOffset / 400, 0), 0.6)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: frosted blur over the home layer with a light dim
            // (the app is dark-only, so the material tints dark), tap to
            // dismiss. Fades with the chrome and thins as the card is
            // dragged, so the fly-back lands on a crisp library.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.2)
            }
            .opacity(expanded ? 1 - dragProgress : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            VStack(spacing: 12) {
                card
                pills
            }
            .padding(.horizontal, 16)
            .padding(.top, safeArea.top + 16)
            .padding(.bottom, safeArea.bottom + 8)
            .offset(y: dragOffset)
            .gesture(dragToDismiss)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            // Screenshot mode arrives already expanded (posed). Otherwise
            // wait one runloop so the cover has been laid out at the row's
            // frame before it flies.
            guard !expanded else { return }
            TrackDetailHaptics.snap.prepare()
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                    expanded = true
                }
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

    // MARK: Card

    private var card: some View {
        VStack(spacing: 24) {
            heading
                .chrome(expanded)

            cover

            if let description {
                Text(description)
                    .font(.social(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .chrome(expanded)
            }

            scrubber
                .chrome(expanded)

            transport
                .chrome(expanded)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(surface)
                .chrome(expanded)
        )
        .overlay(alignment: .topTrailing) {
            if current.owner == true {
                Menu {
                    Button {
                        editingDetails = true
                    } label: {
                        Label("Edit Details", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.systemGray))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(8)
                .chrome(expanded)
            }
        }
    }

    /// The hero. Non-source while collapsed, so it sits on the row's 48pt
    /// artwork; becomes the source as it expands and the row's copy follows
    /// it (hidden). The corner radius tweens from the row's 8pt.
    private var cover: some View {
        TrackArtwork(url: coverURL, symbolFont: .system(size: 56))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 250)
            .clipShape(RoundedRectangle(cornerRadius: expanded ? 28 : 8, style: .continuous))
            .matchedGeometryEffect(id: selection.heroID, in: heroNamespace, isSource: expanded)
    }

    private var heading: some View {
        VStack(spacing: 6) {
            Text(current.title ?? "Untitled")
                .font(.custom("ETBembo-SemiBoldOSF", size: 30, relativeTo: .title))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if !byline.isEmpty {
                Text(byline)
                    .font(.social(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.social(.footnote))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        // Keep the title clear of the owner menu in the corner.
        .padding(.horizontal, 24)
    }

    /// The real waveform doubling as a scrubber (flat bars until the levels
    /// have decoded), with elapsed / total underneath. Its own 0-distance
    /// drag wins over the card's dismiss drag, so scrubbing never moves the
    /// card.
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

    // MARK: Pills

    /// Share + loop in one pill on the left, Edit on the right, floating
    /// under the card on the same surface.
    private var pills: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                if let url = current.webURL {
                    ShareLink(item: url, subject: Text(current.title ?? "Untitled")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .frame(width: 60, height: 56)
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
                        .frame(width: 60, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isLoaded)
                .opacity(isLoaded ? 1 : 0.4)
                .accessibilityLabel("Loop")
            }
            .padding(.horizontal, 8)
            .background(Capsule().fill(surface))

            Spacer(minLength: 0)

            if current.audioURL != nil {
                Button {
                    TrackDetailHaptics.tap.impactOccurred()
                    editingAudio = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.social(.body, weight: .bold))
                        .padding(.horizontal, 28)
                        .frame(height: 56)
                        .background(Capsule().fill(surface))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playbackBlocked)
                .opacity(playbackBlocked ? 0.4 : 1)
            }
        }
        .chrome(expanded)
    }

    // MARK: Dismissal

    /// Drag the card down to dismiss: follows the finger 1:1 downwards,
    /// quarter speed upwards; released with momentum past 140pt it goes.
    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !dismissing, !isScrubbing else { return }
                let dy = value.translation.height
                dragOffset = dy >= 0 ? dy : dy / 4
            }
            .onEnded { value in
                guard !dismissing else { return }
                if value.predictedEndTranslation.height > 140, dragOffset > 0 {
                    // The cover flies back to its row from wherever the
                    // card was let go; the chrome fades out in place.
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        TrackDetailHaptics.snap.impactOccurred(intensity: 0.7)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            expanded = false
        }
        // No animation-completion hook before iOS 17: remove the overlay
        // once the fly-back has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            onDismiss()
        }
    }
}

private extension View {
    /// Card chrome fades in a beat after the cover starts flying, and out
    /// ahead of it on the way back, so the hero reads as the one solid
    /// element throughout.
    func chrome(_ expanded: Bool) -> some View {
        opacity(expanded ? 1 : 0)
            .animation(
                expanded
                    ? .easeOut(duration: 0.3).delay(0.08)
                    : .easeIn(duration: 0.2),
                value: expanded
            )
    }
}
