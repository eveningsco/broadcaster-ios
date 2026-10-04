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
/// hero source. `sourceFrame` is that cover's frame in `HeroSpace` at tap
/// time: where the card's cover flies out from and back to.
struct TrackDetailSelection: Equatable {
    let track: LibraryTrack
    let heroID: String
    var sourceFrame: CGRect = .zero

    static func heroID(list: String, track: LibraryTrack) -> String {
        "\(list)-cover-\(track.id)"
    }
}

/// The coordinate space the hero flies in: `HomeView`'s full-screen ZStack,
/// which hosts both the lists and the detail overlay.
enum HeroSpace {
    static let name = "hero"
}

/// One set of curves for everything that moves with the detail card — the
/// hero, the card surface, its chrome, the pills and the home layer's
/// recession — so the open reads as a single motion rather than parts on
/// their own clocks.
enum TrackDetailMotion {
    /// The hero's flight and the card rising under it.
    static let open = Animation.spring(response: 0.5, dampingFraction: 0.82)
    /// The fly-back: a touch quicker and more damped, it lands rather than bounces.
    static let close = Animation.spring(response: 0.38, dampingFraction: 0.9)
    /// Chrome and pills leaving ahead of the cover on dismiss.
    static let exit = Animation.easeIn(duration: 0.2)
    /// When the overlay can be removed after `close` starts (no
    /// animation-completion hook before iOS 17).
    static let settle: TimeInterval = 0.45

    /// Stagger of the card's chrome behind the cover, top to bottom.
    static let headingDelay: Double = 0.04
    static let scrubberDelay: Double = 0.1
    static let transportDelay: Double = 0.14
    /// The pills land last, left then right.
    static let leftPillDelay: Double = 0.18
    static let rightPillDelay: Double = 0.24
}

/// Frames (in `HeroSpace`) of the list covers that can grow into the detail
/// card, keyed by hero id. Rows publish their own; `HomeView` reads them all
/// for the `track-demo` scene's fingertip.
struct CoverFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Frame of the card's cover slot in the card container's own space.
private struct SlotFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The track detail card, opened by tapping a track's cover in the Library
/// or Explore list. Not a sheet: the 48pt artwork lifts out of its row and
/// grows into the card's cover while the card's chrome fades in around it
/// and the home layer dims and scales back behind.
///
/// The hero is done by hand rather than with `matchedGeometryEffect`: the
/// row reports its cover's frame (`TrackDetailSelection.sourceFrame`), the
/// card lays out an empty slot where the cover goes, and `hero` draws the
/// artwork at whichever of the two frames `expanded` picks, with a
/// value-based spring between them. (Toggling `isSource` on two mounted
/// matched views made the cover jump: SwiftUI only interpolates the
/// non-source view, and the one becoming the source snaps to its layout.)
/// Everything that moves is driven by `.animation(_, value: expanded)`
/// rather than the `withAnimation` in `onAppear`: the CI recordings showed
/// that transaction merging into the overlay's first render, so only the
/// value-animated chrome moved.
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
    /// True once the cover has flown out of its row. Owned by `HomeView` so
    /// the row knows to hide its copy; flipped back on dismiss, and the row
    /// shows its cover again under the one flying home.
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
    /// Where the card's cover sits (card-container space); the hero's
    /// expanded frame. Measured from the slot laid out in `card`.
    @State private var slotFrame: CGRect = .zero

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
            // Stepped in screenshot mode: see HomeView's library layer.
            .animation(
                ScreenshotMode.isActive ? nil : (expanded ? .easeOut(duration: 0.45) : .easeIn(duration: 0.3)),
                value: expanded
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            // Card container: fills the hero space so its own coordinates
            // match it, and carries the drag offset for card and hero alike.
            ZStack {
                VStack(spacing: 12) {
                    card
                    pills
                }
                .padding(.horizontal, 16)
                .padding(.top, safeArea.top + 16)
                .padding(.bottom, safeArea.bottom + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .gesture(dragToDismiss)

                hero
            }
            .coordinateSpace(name: "card")
            .onPreferenceChange(SlotFrameKey.self) { slotFrame = $0 }
            .offset(y: dragOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            // Screenshot mode arrives already expanded (posed). Otherwise
            // wait one runloop so the cover has been laid out at the row's
            // frame before it flies.
            guard !expanded else { return }
            TrackDetailHaptics.snap.prepare()
            DispatchQueue.main.async {
                withAnimation(TrackDetailMotion.open) {
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
        // The surface rises and swells into place on the hero's spring,
        // and the chrome cascades in behind the cover, top to bottom. Only
        // the background and the individual pieces move — the layout stays
        // put so the cover slot the hero flies to never shifts mid-flight.
        VStack(spacing: 24) {
            heading
                .reveal(expanded, delay: TrackDetailMotion.headingDelay)

            coverSlot

            if let description {
                Text(description)
                    .font(.social(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .reveal(expanded, delay: TrackDetailMotion.scrubberDelay)
            }

            scrubber
                .reveal(expanded, delay: TrackDetailMotion.scrubberDelay)

            transport
                .reveal(expanded, delay: TrackDetailMotion.transportDelay)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(surface)
                .reveal(expanded, rise: 28, scale: 0.96)
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
                .reveal(expanded, delay: TrackDetailMotion.transportDelay, rise: 0)
            }
        }
    }

    /// Where the cover goes in the card's layout; the hero draws over it.
    private var coverSlot: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 250)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SlotFrameKey.self, value: geometry.frame(in: .named("card")))
            })
    }

    /// The hero: the artwork, drawn at the row's 48pt frame while collapsed
    /// and at the card's slot once expanded, springing between the two. It
    /// is laid out at slot size and scaled, so the image never re-lays-out
    /// mid-flight; the corner radius reads 8pt small and 28pt large. The
    /// container carries `dragOffset`, so the collapsed target compensates
    /// to land on the row wherever the card was let go.
    private var hero: some View {
        let slot = slotFrame.width > 0 ? slotFrame : CGRect(x: 0, y: 0, width: 250, height: 250)
        let source = selection.sourceFrame.width > 0
            ? selection.sourceFrame
            : CGRect(x: slot.midX - 24, y: slot.midY - 24, width: 48, height: 48)
        let target = expanded ? slot : source
        let scale = target.width / slot.width
        return TrackArtwork(url: coverURL, symbolFont: .system(size: 56))
            .frame(width: slot.width, height: slot.height)
            .clipShape(RoundedRectangle(cornerRadius: expanded ? 28 : 8 / scale, style: .continuous))
            .scaleEffect(scale)
            .position(x: target.midX, y: expanded ? target.midY : target.midY - dragOffset)
            .animation(expanded ? TrackDetailMotion.open : TrackDetailMotion.close, value: expanded)
            .allowsHitTesting(false)
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
    /// under the card on the same surface. They land last: each rises from
    /// below its resting spot and swells up, left a beat before right, and
    /// drops away first on dismiss.
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
            .reveal(expanded, delay: TrackDetailMotion.leftPillDelay, rise: 44, scale: 0.86)

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
                .reveal(expanded, delay: TrackDetailMotion.rightPillDelay, rise: 44, scale: 0.86)
            }
        }
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
        withAnimation(TrackDetailMotion.close) {
            expanded = false
        }
        // No animation-completion hook before iOS 17: remove the overlay
        // once the fly-back has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + TrackDetailMotion.settle) {
            onDismiss()
        }
    }
}

/// How a piece of the card arrives and leaves. In: fades up from `rise`
/// points below (and from `scale`, anchored at its bottom edge) on the
/// hero's spring, after `delay` — so the chrome cascades in behind the
/// cover and the pills land last. Out: the reverse, quick and undelayed,
/// so everything is gone before the cover reaches its row.
private struct Reveal: ViewModifier {
    let expanded: Bool
    let delay: Double
    let rise: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(expanded ? 1 : 0)
            .scaleEffect(expanded ? 1 : scale, anchor: .bottom)
            .offset(y: expanded ? 0 : rise)
            .animation(
                expanded ? TrackDetailMotion.open.delay(delay) : TrackDetailMotion.exit,
                value: expanded
            )
    }
}

private extension View {
    func reveal(_ expanded: Bool, delay: Double = 0, rise: CGFloat = 16, scale: CGFloat = 1) -> some View {
        modifier(Reveal(expanded: expanded, delay: delay, rise: rise, scale: scale))
    }
}
