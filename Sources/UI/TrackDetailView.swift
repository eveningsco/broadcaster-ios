import SwiftUI
import UIKit

/// Soft tap for the transport controls, matching row selection.
private enum TrackDetailHaptics {
    static let tap = UIImpactFeedbackGenerator(style: .light)
    static let snap = UIImpactFeedbackGenerator(style: .medium)
}

/// The list a detail card opened from — and pages through sideways.
enum TrackList: String {
    case library
    case explore
}

/// Which track the detail card is showing, and which list it came from.
/// The hero id names the list too (`library-cover-12`, `explore-cover-12`)
/// so a track present in both lists has exactly one hero source.
/// `sourceFrame` is the current track's row cover frame in `HeroSpace`:
/// where the card's cover flies out from and back to. It is the tapped
/// cover's frame at tap time; after paging it is re-resolved from the
/// rows on screen, and `.zero` when the current track's row isn't visible
/// (the cover then shrinks away in place on dismiss).
struct TrackDetailSelection: Equatable {
    var track: LibraryTrack
    let list: TrackList
    var sourceFrame: CGRect = .zero

    var heroID: String { Self.heroID(list: list, track: track) }

    static func heroID(list: TrackList, track: LibraryTrack) -> String {
        "\(list.rawValue)-cover-\(track.id)"
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
    /// 1 on device. The recorded `track-demo` scene plays at half speed
    /// (2): the CI simulator draws ~15 fps, which turns a 0.36 s spring
    /// into four or five frames — too few to read as motion.
    static let timeScale: Double = ScreenshotMode.recordsDetails ? 2 : 1
    /// The hero's flight and the card rising under it. Quick (osebo asked
    /// for a faster open/close, 2026-10-05) with a hint of overshoot so
    /// it still reads as a lift rather than a cut.
    static let open = Animation.spring(response: openResponse, dampingFraction: openDamping).speed(1 / timeScale)
    static let openResponse: Double = 0.36
    static let openDamping: Double = 0.82
    /// The fly-back: quicker and more damped, it lands rather than bounces.
    static let close = Animation.spring(response: closeResponse, dampingFraction: closeDamping).speed(1 / timeScale)
    static let closeResponse: Double = 0.28
    static let closeDamping: Double = 0.9
    /// Chrome and pills leaving ahead of the cover on dismiss.
    static let exit = Animation.easeIn(duration: 0.14 * timeScale)
    /// Backdrop dim/frost fading with the card on device (the recording
    /// rides `open`/`exit` instead; see `TrackDetailOverlay.backdropAnimation`).
    static let backdropIn = Animation.easeOut(duration: 0.32 * timeScale)
    static let backdropOut = Animation.easeIn(duration: 0.2 * timeScale)
    /// Paging sideways to the next / previous track commits on the open
    /// spring — the neighbour's content lands the way the card arrived.
    static let page = open
    /// A released drag that didn't commit (dismiss or page) settling back.
    static let snapBack = Animation.spring(response: 0.35, dampingFraction: 0.82)
    /// When the overlay can be removed after `close` starts (no
    /// animation-completion hook before iOS 17): the spring's settling
    /// time, so the cover is at rest on its row — not a hand-picked
    /// number that drifts when the spring is retuned. Removing the overlay
    /// early snapped the cover the last pixel or two (osebo, 2026-10-05).
    static let settle: TimeInterval = settlingTime(response: closeResponse, dampingFraction: closeDamping) * timeScale
    /// When the open flight has landed (the heroes are clipped to the
    /// card from then on; see `TrackDetailOverlay.heroes`).
    static let openSettle: TimeInterval = settlingTime(response: openResponse, dampingFraction: openDamping) * timeScale

    /// How long an underdamped spring takes to stay within `epsilon` of
    /// its target (the envelope of the step response, as in
    /// `Spring.settlingDuration`).
    static func settlingTime(response: Double, dampingFraction zeta: Double, epsilon: Double = 0.001) -> TimeInterval {
        let omega = 2 * Double.pi / response
        let envelope = 1 / (1 - zeta * zeta).squareRoot()
        return log(envelope / epsilon) / (zeta * omega)
    }

    /// Stagger of the card's chrome behind the cover, top to bottom.
    /// (Applied after `speed`, so scaled by hand.) The whole cascade
    /// starts within 0.16 s so it ends with the hero, not after it.
    static let headingDelay: Double = 0.03 * timeScale
    static let scrubberDelay: Double = 0.06 * timeScale
    static let transportDelay: Double = 0.09 * timeScale
    /// The pills land last, left to right.
    static let leftPillDelay: Double = 0.12 * timeScale
    static let middlePillDelay: Double = 0.14 * timeScale
    static let rightPillDelay: Double = 0.16 * timeScale
}

/// Frames (in `HeroSpace`) of the list covers that can grow into the detail
/// card, keyed by hero id (plus the library card's own frames under
/// `HomeFrames` keys). Rows publish their own; `HomeView` keeps the resting
/// set for the fly-back after paging and the `track-demo` fingertip.
struct CoverFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Frame of each page's cover slot in that page's own coordinate space,
/// by track id.
private struct SlotFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Natural height of each page's content, by track id.
private struct PageHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Frame of the card's page strip in the card container's own space.
private struct StripFrameKey: PreferenceKey {
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
/// card lays out an empty slot where the cover goes, and `hero(for:)` draws
/// the artwork at whichever of the two frames `expanded` picks, with a
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
/// elapsed/total, and a transport (−15 s, play/pause, +15 s). Three pills
/// float under it: Share, Loop and Edit, the last of which opens
/// the combined audio editor (`AudioEditSheet`). Owners get Edit Details
/// from a `…` in the card's corner.
///
/// Swipe sideways to page to the next / previous track in the list the
/// card opened from (osebo, 2026-10-05). The card's content is a strip of
/// up to three pages — previous, current, next — that follows the finger,
/// and the covers ride along in the hero layer, so the current cover
/// slides out as its neighbour slides in; releasing past a third of the
/// width (or flicking) commits on `TrackDetailMotion.page`, otherwise it
/// springs back. Pages are bottom-aligned in the strip, so when a taller
/// or shorter page lands the card grows or shrinks from its top edge and
/// no cover moves except the ones paging. After paging, dismiss flies the
/// cover back to the *current* track's row if that row is on screen (the
/// resting row frames come from `HomeView`), else it shrinks away in place.
///
/// Dismiss by dragging the card down (tracks the finger, rubber-banded
/// upwards; release with momentum and the cover flies back into its row) or
/// by tapping the backdrop. One drag gesture serves both: its first
/// movement locks it to the vertical (dismiss) or horizontal (page) lane.
/// While dragging only cheap things change: the container's offset or the
/// strip's shift, and the solid dim's opacity. The frosted material keeps
/// a constant opacity until the drag commits — re-rendering a full-screen
/// material at a new opacity every frame is what made the drag stutter
/// (osebo, 2026-10-05), and a thinned frost also exposed the home layer's
/// stepped un-blur as a pop on release.
///
/// Playback goes through the shared `TrackPlayer`, so the home mini player,
/// the lock screen and this card all show the same position. Paging does
/// not start the neighbour playing; the card never owned audio.
struct TrackDetailOverlay: View {
    @EnvironmentObject private var model: AppModel
    /// Owned by `HomeView` (`detail`): the track changes as the card pages,
    /// so the rows' `coverHidden` follows the page.
    @Binding var selection: TrackDetailSelection
    @ObservedObject var player: TrackPlayer
    /// True once the cover has flown out of its row; flipped back on
    /// dismiss to fly it home. Owned by `HomeView` (it drives the home
    /// layer's recession). The row's own cover stays hidden for as long as
    /// the overlay is mounted — not just while expanded — so there is one
    /// visible cover throughout; the row's reappears under the hero only
    /// when `onDismiss` removes the overlay.
    @Binding var expanded: Bool
    let safeArea: EdgeInsets
    /// The resting frame (in `HeroSpace`) of a list row's cover, by hero
    /// id, if that row is fully in view — the fly-back target after paging.
    /// Nil means "shrink away instead".
    var rowFrame: (String) -> CGRect? = { _ in nil }
    /// Called once the fly-back animation has finished; removes the overlay.
    let onDismiss: () -> Void

    @StateObject private var waveform = WaveformLoader()
    @State private var isScrubbing = false
    @State private var editingAudio = false
    @State private var editingDetails = false
    /// Which lane the card drag locked into on its first movement.
    private enum DragAxis {
        case vertical
        case horizontal
    }
    @State private var dragAxis: DragAxis?
    /// Vertical card displacement while dragging to dismiss.
    @State private var dragOffset: CGFloat = 0
    /// Horizontal shift of the page strip (and the covers) while paging.
    @State private var pageDrag: CGFloat = 0
    @State private var dismissing = false
    /// The tapped track and its row frame at tap time: the fly-back target
    /// for that track even if the viewport check would rule its row out.
    @State private var origin: (id: Int, frame: CGRect)?
    /// Where the page strip sits (card-container space). Its bottom edge is
    /// fixed — the card is bottom-anchored — so cover positions are
    /// measured up from it.
    @State private var stripFrame: CGRect = .zero
    /// Each page's cover slot in that page's own space, and each page's
    /// natural height; together they place the heroes.
    @State private var slotFrames: [Int: CGRect] = [:]
    @State private var pageHeights: [Int: CGFloat] = [:]
    /// How the heroes' sideways shift animates: nil while a finger drives
    /// it, the page spring on commit, `snapBack` on a released drag that
    /// didn't commit. Set before each write to `pageDrag` / the current
    /// track; see `hero(for:)` for why the heroes need their own.
    @State private var pageAnimation: Animation? = TrackDetailMotion.page
    /// `page-demo` only: the ghost fingertip's position (card space)
    /// while it swipes the strip; nil when lifted.
    @State private var demoFinger: CGPoint?

    private var track: LibraryTrack { selection.track }

    /// Screenshot mode's `track` scene: nothing is loaded (no network), so
    /// the scrubber, readout and play state pose from fixtures.
    private var isFixture: Bool { ScreenshotMode.isActive }

    /// Display reads the live copy so a title edit shows up immediately.
    private var current: LibraryTrack { live(track) }

    private func live(_ track: LibraryTrack) -> LibraryTrack {
        model.library.first { $0.id == track.id }
            ?? model.exploreTracks.first { $0.id == track.id }
            ?? track
    }

    // MARK: Pages

    /// The list the card pages through, in row order.
    private var tracks: [LibraryTrack] {
        switch selection.list {
        case .library: return model.library
        case .explore: return model.exploreTracks
        }
    }

    private var pageIndex: Int? {
        tracks.firstIndex { $0.id == track.id }
    }

    private var previousTrack: LibraryTrack? {
        guard let index = pageIndex, index > 0 else { return nil }
        return tracks[index - 1]
    }

    private var nextTrack: LibraryTrack? {
        guard let index = pageIndex, index + 1 < tracks.count else { return nil }
        return tracks[index + 1]
    }

    /// One page of the strip: a track and where it sits relative to the
    /// current one (−1 previous, 0 current, 1 next).
    private struct Page: Identifiable {
        let track: LibraryTrack
        let position: Int
        var id: Int { track.id }
    }

    /// The pages in the strip. Neighbours exist only while the card is
    /// expanded and the strip has been measured (before that they'd be
    /// laid out on top of the current page for a frame).
    private var pages: [Page] {
        guard expanded, stripFrame.width > 0 else {
            return [Page(track: current, position: 0)]
        }
        var result: [Page] = []
        if let previousTrack {
            result.append(Page(track: live(previousTrack), position: -1))
        }
        result.append(Page(track: current, position: 0))
        if let nextTrack {
            result.append(Page(track: live(nextTrack), position: 1))
        }
        return result
    }

    /// Distance between neighbouring pages: the strip's width plus a
    /// gutter, so one page has fully left before the next arrives.
    private var pageStride: CGFloat { stripFrame.width + 24 }

    /// A page's horizontal shift from the current page's place.
    private func pageShift(_ page: Page) -> CGFloat {
        CGFloat(page.position) * pageStride + pageDrag
    }

    private func pageSpace(_ track: LibraryTrack) -> String {
        "page-\(track.id)"
    }

    // MARK: Per-track state

    private func key(_ track: LibraryTrack) -> String { TrackPlayer.key(for: track) }
    /// This track is the one in the player (playing or paused).
    private func isLoaded(_ track: LibraryTrack) -> Bool { isFixture || player.playingKey == key(track) }
    private func isPlaying(_ track: LibraryTrack) -> Bool { isFixture || (isLoaded(track) && !player.isPaused) }
    private func progress(_ track: LibraryTrack) -> Double {
        if isFixture { return ScreenshotFixtures.editPlayhead }
        return isLoaded(track) ? player.progress : 0
    }
    /// Decoded levels for the current track, or a neighbour's if they were
    /// decoded while it was current (flat bars otherwise).
    private func levels(_ track: LibraryTrack) -> [Float]? {
        waveform.levels(for: key(track)) ?? (isFixture ? ScreenshotFixtures.editWaveform : nil)
    }
    private func totalDuration(_ track: LibraryTrack) -> TimeInterval { TimeInterval(track.duration ?? 0) }
    private func elapsed(_ track: LibraryTrack) -> TimeInterval { progress(track) * totalDuration(track) }

    /// The mic owns the audio session while broadcasting, same rule as the
    /// list rows and the editor.
    private var playbackBlocked: Bool { model.broadcast.state.isActive }

    private func coverURL(for track: LibraryTrack) -> URL? {
        (track.image ?? track.station?.image).flatMap(URL.init(string:))
    }

    private func byline(of track: LibraryTrack) -> String {
        var parts: [String] = []
        if let station = track.station?.name {
            parts.append(station)
        }
        if let date = track.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func description(of track: LibraryTrack) -> String? {
        let text = (track.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The card's surface; the pills share it so they read as one set.
    /// Pure black (osebo, 2026-10-05) rather than the system's off-grey;
    /// `edge` is a faint hairline that keeps the black shapes separable
    /// from the dark frosted backdrop behind them.
    private let surface = Color.black
    private let edge = Color.white.opacity(0.08)
    private let cardCorner: CGFloat = 40
    /// The strip's inset from the card's top and bottom edges.
    private let stripTopInset: CGFloat = 32
    private let stripBottomInset: CGFloat = 24

    /// How far along the drag-to-dismiss is (0 at rest, 0.6 well past the
    /// commit distance); thins the backdrop's dim as the card goes. Only
    /// the solid dim reads it — never the material (see `backdrop`).
    private var dragProgress: CGFloat {
        min(max(dragOffset / 400, 0), 0.6)
    }

    /// Recorded demo only: whether the frosted backdrop is in (it follows
    /// the hero's settle rather than the flight; see `body`).
    @State private var frosted = false
    /// Whether the heroes are clipped to the card (true once the open
    /// flight has landed, false the instant a dismiss starts). See `heroes`.
    @State private var heroClipped = false

    private var backdropAnimation: Animation? {
        if ScreenshotMode.recordsDetails {
            return expanded ? TrackDetailMotion.open : TrackDetailMotion.exit
        }
        // Posed stills arrive expanded, nothing to animate.
        if ScreenshotMode.isActive { return nil }
        return expanded ? TrackDetailMotion.backdropIn : TrackDetailMotion.backdropOut
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop

            // Card container: fills the hero space so its own coordinates
            // match it, and carries the drag offset for card and heroes alike.
            ZStack {
                VStack(spacing: 12) {
                    card
                    pills
                }
                .padding(.horizontal, 16)
                .padding(.top, safeArea.top + 16)
                .padding(.bottom, safeArea.bottom + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .gesture(cardDrag)

                heroes

                if let demoFinger {
                    DemoFingertip()
                        .position(demoFinger)
                }
            }
            .coordinateSpace(name: "card")
            .onPreferenceChange(StripFrameKey.self) { stripFrame = $0 }
            .onPreferenceChange(SlotFramesKey.self) { slotFrames = $0 }
            .onPreferenceChange(PageHeightsKey.self) { pageHeights = $0 }
            .offset(y: dragOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Taps go through to the library while the cover settles on its row.
        .allowsHitTesting(!dismissing)
        .onChange(of: expanded) { expanded in
            if expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + TrackDetailMotion.openSettle) {
                    if self.expanded { heroClipped = true }
                }
                if ScreenshotMode.recordsDetails {
                    DispatchQueue.main.asyncAfter(deadline: .now() + TrackDetailMotion.settle) {
                        if self.expanded { frosted = true }
                    }
                }
            } else {
                heroClipped = false
                frosted = false
            }
        }
        .onAppear {
            origin = (selection.track.id, selection.sourceFrame)
            // Screenshot mode arrives already expanded (posed). Otherwise
            // wait one runloop so the cover has been laid out at the row's
            // frame before it flies.
            guard !expanded else { frosted = true; heroClipped = true; return }
            TrackDetailHaptics.snap.prepare()
            DispatchQueue.main.async {
                withAnimation(TrackDetailMotion.open) {
                    expanded = true
                }
            }
        }
        // Reloads when the card pages (cached once decoded, so paging back
        // is instant).
        .task(id: current.id) {
            guard !isFixture else { return }
            waveform.load(key: key(current), url: current.audioURL, buckets: 48)
        }
        .task {
            guard ScreenshotMode.pagesDetails else { return }
            await runPageDemo()
        }
        .sheet(isPresented: $editingAudio) {
            AudioEditSheet(track: current)
        }
        .sheet(isPresented: $editingDetails) {
            EditTrackSheet(track: current)
        }
    }

    // MARK: Backdrop

    /// Frosted blur over the home layer with a light dim (the app is
    /// dark-only, so the material tints dark); tap to dismiss. Both fade
    /// with the chrome on open/close. Only the solid dim thins while the
    /// card is dragged: the material's opacity changes just twice per
    /// presentation, never per frame, so the drag stays on the cheap
    /// compositing path and the frost keeps hiding the home layer's
    /// stepped un-blur until the drag commits.
    ///
    /// Recorded (`track-demo`): the CI simulator software-renders a
    /// material over a moving layer so slowly that the whole flight would
    /// be skipped, so a plain dim tweens with the hero and the frost
    /// arrives only once everything below it has settled (`frosted`); it
    /// leaves instantly on dismiss.
    private var backdrop: some View {
        ZStack {
            if ScreenshotMode.recordsDetails {
                Color.black.opacity(0.55)
                    .opacity(expanded ? 1 : 0)
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.2))
                    .opacity(frosted ? 1 : 0)
                    .animation(frosted ? Animation.easeOut(duration: 0.3) : nil, value: frosted)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(expanded ? 1 : 0)
                Color.black.opacity(0.2)
                    .opacity(expanded ? 1 - dragProgress : 0)
            }
        }
        .animation(backdropAnimation, value: expanded)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }

    // MARK: Card

    private var card: some View {
        // The surface rises and swells into place on the hero's spring,
        // and the chrome cascades in behind the cover, top to bottom. Only
        // the background and the individual pieces move — the layout stays
        // put so the cover slots the heroes fly to never shift mid-flight.
        strip
            .padding(.top, stripTopInset)
            .padding(.bottom, stripBottomInset)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                            .strokeBorder(edge, lineWidth: 1)
                    )
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

    /// The pages side by side, the current one deciding the card's height.
    /// Bottom-aligned: the card is anchored to the bottom of the screen, so
    /// a height change moves the card's top edge and nothing else — the
    /// resting covers stay exactly where they are. Clipped to the card's
    /// edges (not the strip's), so a taller neighbour sliding in is cut at
    /// the card's top and the chrome's reveal rise isn't.
    private var strip: some View {
        ZStack(alignment: .bottom) {
            ForEach(pages) { page in
                pageContent(page)
                    .offset(x: pageShift(page))
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: pageHeights[current.id], alignment: .bottom)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: StripFrameKey.self, value: geometry.frame(in: .named("card")))
        })
        .mask {
            Rectangle()
                .padding(.top, -stripTopInset)
                .padding(.bottom, -stripBottomInset)
        }
    }

    /// One page: heading, cover slot, description, scrubber, transport for
    /// its track. Always its natural height (never squeezed to the strip's
    /// animating frame) and measured, so the strip can take the current
    /// page's height and the hero can find the slot.
    private func pageContent(_ page: Page) -> some View {
        let track = page.track
        return VStack(spacing: 24) {
            heading(for: track)
                .reveal(expanded, delay: TrackDetailMotion.headingDelay)

            coverSlot(for: track)

            if let description = description(of: track) {
                Text(description)
                    .font(.social(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .reveal(expanded, delay: TrackDetailMotion.scrubberDelay)
            }

            scrubber(for: track)
                .reveal(expanded, delay: TrackDetailMotion.scrubberDelay)

            transport(for: track)
                .reveal(expanded, delay: TrackDetailMotion.transportDelay)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PageHeightsKey.self, value: [track.id: geometry.size.height])
        })
        .coordinateSpace(name: pageSpace(track))
    }

    /// Where the cover goes in a page's layout; the hero draws over it.
    private func coverSlot(for track: LibraryTrack) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 250)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: SlotFramesKey.self,
                    value: [track.id: geometry.frame(in: .named(pageSpace(track)))]
                )
            })
    }

    // MARK: Heroes

    /// The covers, one per page, drawn over the card. Clipped to the
    /// card's width always — so a cover paging out is cut at the card's
    /// edge like the content under it — and to the card's full bounds
    /// once the open flight has landed (`heroClipped`), released the
    /// instant a dismiss starts so the current cover can fly down to its
    /// row. The clip is never animated: it must be there or not, never
    /// half-way across a flying cover.
    ///
    /// Clipping to the card is also what makes the covers move in the CI
    /// recordings. The hero group is otherwise screen-sized and overlaps
    /// the frosted backdrop; on the software-rendered CI simulator the
    /// material re-renders behind every change to that region and the
    /// covers' sideways motion was dropped wholesale — they jumped to the
    /// swipe's end point while the strip's text (inside the opaque card)
    /// tweened — in three recordings with three different animation
    /// wirings (runs 37260289707, 37261598128, 37262716674). The open
    /// flight, which the recorded scenes run with the frost off, always
    /// animated.
    private var heroes: some View {
        ZStack {
            ForEach(pages) { page in
                hero(for: page)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask {
            GeometryReader { geometry in
                let clip = heroClip(in: geometry.size)
                Rectangle()
                    .frame(width: clip.width, height: clip.height)
                    .position(x: clip.midX, y: clip.midY)
            }
            .transaction { $0.animation = nil }
        }
        .allowsHitTesting(false)
    }

    /// The card's frame in the card container's space (the strip plus its
    /// insets), or the full width before the strip has been measured.
    private func heroClip(in size: CGSize) -> CGRect {
        guard stripFrame.width > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        if heroClipped {
            return CGRect(
                x: stripFrame.minX,
                y: stripFrame.minY - stripTopInset,
                width: stripFrame.width,
                height: stripFrame.height + stripTopInset + stripBottomInset
            )
        }
        return CGRect(x: stripFrame.minX, y: 0, width: stripFrame.width, height: size.height)
    }

    /// A page's hero: the artwork, drawn at the row's 48pt frame while
    /// collapsed and at its page's cover slot once expanded, springing
    /// between the two. It is laid out at slot size and scaled, so the
    /// image never re-lays-out mid-flight; the corner radius reads 8pt
    /// small and 28pt large. The slot is placed from the strip's fixed
    /// bottom edge. The container carries `dragOffset`, so the collapsed
    /// target compensates to land on the row wherever the card was let
    /// go. With no row to land on (paged to a track whose row is off
    /// screen) the cover shrinks and fades in place instead.
    ///
    /// The page shift is a separate `.offset` with its own value-keyed
    /// animation (`pageAnimation`, keyed on the shift itself). The hero
    /// does not pick up the `withAnimation` transactions that move the
    /// strip's text: with the shift folded into `.position` under the
    /// `expanded` animation, and again with it as an un-keyed `.offset`
    /// outside that modifier, the covers ignored both the drag tween and
    /// the `page(to:)` spring — they jumped to the finger's end point as
    /// the swipe began and snapped to centre at commit while the text was
    /// still sliding (osebo, 2026-10-05; CI runs 37260289707 and
    /// 37261598128, measured frame by frame). The `expanded`-keyed flight
    /// has always animated, so the shift gets the same treatment: an
    /// explicit animation that fires when the shift changes — nil while
    /// the finger is down (1:1), the page spring on commit.
    private func hero(for page: Page) -> some View {
        let track = page.track
        let slot = slotFrames[track.id]
            ?? CGRect(x: (stripFrame.width - 250) / 2, y: 0, width: 250, height: 250)
        let pageHeight = pageHeights[track.id] ?? slot.maxY
        let slotFrame = CGRect(
            x: stripFrame.minX + slot.minX,
            y: stripFrame.maxY - (pageHeight - slot.minY),
            width: slot.width,
            height: slot.height
        )
        let isCurrent = page.position == 0
        let source = selection.sourceFrame
        let hasSource = source.width > 0
        let shrunk = CGRect(x: slotFrame.midX - 24, y: slotFrame.midY - 24, width: 48, height: 48)
        let flies = isCurrent && !expanded
        let target = flies ? (hasSource ? source : shrunk) : slotFrame
        let scale = target.width / slot.width
        return TrackArtwork(url: coverURL(for: track), symbolFont: .system(size: 56))
            .frame(width: slot.width, height: slot.height)
            .clipShape(RoundedRectangle(cornerRadius: flies ? 8 / scale : 28, style: .continuous))
            .scaleEffect(scale)
            .position(x: target.midX, y: flies ? target.midY - dragOffset : target.midY)
            .opacity(flies && !hasSource ? 0 : 1)
            .animation(expanded ? TrackDetailMotion.open : TrackDetailMotion.close, value: expanded)
            // Paging shift, self-animated (see above). Zero for the
            // current page at rest, so the fly-back is unaffected.
            .offset(x: pageShift(page))
            .animation(pageAnimation, value: pageShift(page))
    }

    // MARK: Chrome

    private func heading(for track: LibraryTrack) -> some View {
        let subtitle = byline(of: track)
        return VStack(spacing: 6) {
            Text(track.title ?? "Untitled")
                .font(.custom("ETBembo-SemiBoldOSF", size: 30, relativeTo: .title))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.social(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        // Keep the title clear of the owner menu in the corner.
        .padding(.horizontal, 24)
    }

    /// The real waveform doubling as a scrubber (flat bars until the levels
    /// have decoded), with elapsed / total underneath. Its own 0-distance
    /// drag wins over the card's drag, so scrubbing never moves the card.
    private func scrubber(for track: LibraryTrack) -> some View {
        VStack(spacing: 12) {
            PlayingWaveform(
                levels: levels(track),
                progress: progress(track),
                onScrub: { fraction in
                    guard !playbackBlocked else { return }
                    if isLoaded(track) {
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

            Text("\(AudioEditSheet.format(elapsed(track))) / \(AudioEditSheet.format(totalDuration(track)))")
                .font(.social(.footnote))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func transport(for track: LibraryTrack) -> some View {
        let loaded = isLoaded(track)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            transportButton("gobackward.15", label: "Back 15 seconds") {
                player.skip(by: -15)
            }
            .disabled(!loaded)
            .opacity(loaded ? 1 : 0.4)
            Spacer(minLength: 0)
            Button {
                TrackDetailHaptics.tap.impactOccurred()
                player.toggle(track)
            } label: {
                Image(systemName: isPlaying(track) ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .medium))
                    .frame(width: 72, height: 72)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying(track) ? "Pause" : "Play")
            Spacer(minLength: 0)
            transportButton("goforward.15", label: "Forward 15 seconds") {
                player.skip(by: 15)
            }
            .disabled(!loaded)
            .opacity(loaded ? 1 : 0.4)
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

    /// Three labelled pills under the card on the same surface: Share,
    /// Loop and Edit, equal widths. They land last: each rises from below
    /// its resting spot and swells up, left to right a beat apart, and
    /// drops away first on dismiss. They stay put while paging and simply
    /// read the current track.
    private var pills: some View {
        let loaded = isLoaded(current)
        return HStack(spacing: 12) {
            if let url = current.webURL {
                ShareLink(item: url, subject: Text(current.title ?? "Untitled")) {
                    pillLabel("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share link")
                .reveal(expanded, delay: TrackDetailMotion.leftPillDelay, rise: 44, scale: 0.86)
            }

            Button {
                TrackDetailHaptics.tap.impactOccurred()
                player.toggleLooping()
            } label: {
                pillLabel("Loop", systemImage: "repeat",
                          tint: player.isLoopingCurrent && loaded ? Color.eveningsRed : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!loaded)
            .opacity(loaded ? 1 : 0.4)
            .accessibilityLabel("Loop")
            .accessibilityAddTraits(player.isLoopingCurrent && loaded ? .isSelected : [])
            .reveal(expanded, delay: TrackDetailMotion.middlePillDelay, rise: 44, scale: 0.86)

            if current.audioURL != nil {
                Button {
                    TrackDetailHaptics.tap.impactOccurred()
                    editingAudio = true
                } label: {
                    pillLabel("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .disabled(playbackBlocked)
                .opacity(playbackBlocked ? 0.4 : 1)
                .reveal(expanded, delay: TrackDetailMotion.rightPillDelay, rise: 44, scale: 0.86)
            }
        }
    }

    /// One pill's face: icon + bold label, centred, on the card's surface.
    /// All three share it so they read as one set.
    private func pillLabel(_ title: String, systemImage: String, tint: Color = .primary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.social(.body, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Capsule().fill(surface))
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .contentShape(Capsule())
    }

    // MARK: Drag: dismiss or page

    /// One drag on the card, locked on its first movement to a lane.
    /// Vertical: drag the card down to dismiss — follows the finger 1:1
    /// downwards, quarter speed upwards; released with momentum past 140pt
    /// it goes. Horizontal: page the strip — follows the finger 1:1 when
    /// there is a neighbour that way, quarter speed against the end of the
    /// list; released past a third of the stride (or flicked) it commits.
    /// Measured in global space: the card moves with the finger, so a
    /// translation read in its own (moving) space would feed back on
    /// itself.
    private var cardDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !dismissing, !isScrubbing else { return }
                let translation = value.translation
                let axis: DragAxis = dragAxis
                    ?? (abs(translation.width) > abs(translation.height) ? .horizontal : .vertical)
                dragAxis = axis
                switch axis {
                case .vertical:
                    let dy = translation.height
                    dragOffset = dy >= 0 ? dy : dy / 4
                case .horizontal:
                    let dx = translation.width
                    let hasNeighbour = dx < 0 ? nextTrack != nil : previousTrack != nil
                    // The finger drives the covers directly.
                    pageAnimation = nil
                    pageDrag = hasNeighbour ? dx : dx / 4
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard !dismissing else { return }
                switch axis {
                case .vertical?:
                    if value.predictedEndTranslation.height > 140, dragOffset > 0 {
                        // The cover flies back to its row from wherever the
                        // card was let go; the chrome fades out in place.
                        dismiss()
                    } else {
                        withAnimation(TrackDetailMotion.snapBack) {
                            dragOffset = 0
                        }
                    }
                case .horizontal?:
                    let dx = value.translation.width
                    let predicted = value.predictedEndTranslation.width
                    let threshold = pageStride / 3
                    if dx < 0, let next = nextTrack, min(dx, predicted) < -threshold {
                        page(to: next)
                    } else if dx > 0, let previous = previousTrack, max(dx, predicted) > threshold {
                        page(to: previous)
                    } else {
                        pageAnimation = TrackDetailMotion.snapBack
                        withAnimation(TrackDetailMotion.snapBack) {
                            pageDrag = 0
                        }
                    }
                case nil:
                    break
                }
            }
    }

    /// The `page-demo` recording: swipe the strip the way a finger would
    /// — touch down over the cover, pull it `0.45 × stride` sideways (past
    /// the ⅓ commit threshold) on an ease, lift, and commit through the
    /// same `page(to:)` the gesture uses, so what's recorded is the real
    /// paging motion. `HomeView.runTrackDemo` holds the card open for
    /// `PageDemoScript.total` meanwhile.
    @MainActor
    private func runPageDemo() async {
        try? await Task.sleep(for: .seconds(PageDemoScript.settle))
        for direction in PageDemoScript.swipes {
            let neighbour = direction < 0 ? nextTrack : previousTrack
            guard let neighbour, stripFrame.width > 0 else { continue }
            let slot = slotFrames[current.id]
                ?? CGRect(x: (stripFrame.width - 250) / 2, y: 0, width: 250, height: 250)
            let pageHeight = pageHeights[current.id] ?? slot.maxY
            let fingerY = stripFrame.maxY - (pageHeight - slot.minY) + slot.height * 0.62
            let travel = CGFloat(direction) * pageStride * 0.45
            let start = CGPoint(x: stripFrame.midX - travel / 2, y: fingerY)

            withAnimation(.easeOut(duration: 0.18)) {
                demoFinger = start
            }
            try? await Task.sleep(for: .seconds(PageDemoScript.touch))
            // A finger would drive the covers directly; the scripted swipe
            // tweens them on the same curve as the strip and the fingertip.
            pageAnimation = .easeInOut(duration: PageDemoScript.swipe)
            withAnimation(.easeInOut(duration: PageDemoScript.swipe)) {
                demoFinger = CGPoint(x: start.x + travel, y: fingerY)
                pageDrag = travel
            }
            try? await Task.sleep(for: .seconds(PageDemoScript.swipe + 0.1))
            withAnimation(.easeOut(duration: 0.18)) {
                demoFinger = nil
            }
            page(to: neighbour)
            try? await Task.sleep(for: .seconds(PageDemoScript.hold))
        }
    }

    /// Commit a page: the neighbour becomes the current track and the
    /// strip's shift returns to zero in one animated change, so every page
    /// (and every cover) glides from where the finger left it to its new
    /// resting place. Its row's resting frame — if the row is on screen —
    /// becomes the fly-back target.
    private func page(to track: LibraryTrack) {
        TrackDetailHaptics.tap.impactOccurred()
        let heroID = TrackDetailSelection.heroID(list: selection.list, track: track)
        pageAnimation = TrackDetailMotion.page
        withAnimation(TrackDetailMotion.page) {
            selection.track = track
            selection.sourceFrame = resolvedRowFrame(for: track, heroID: heroID) ?? .zero
            pageDrag = 0
        }
        // Nearing the end of what's loaded: fetch the next page of the list.
        Task { await loadMore(after: track) }
    }

    /// The row frame to fly back to: the row if it's on screen, else the
    /// tapped frame for the track that was tapped (its row was under the
    /// finger, so it is visible whatever the viewport check says).
    private func resolvedRowFrame(for track: LibraryTrack, heroID: String) -> CGRect? {
        if let frame = rowFrame(heroID) { return frame }
        if let origin, origin.id == track.id, origin.frame.width > 0 { return origin.frame }
        return nil
    }

    private func loadMore(after track: LibraryTrack) async {
        switch selection.list {
        case .library: await model.loadMoreLibraryIfNeeded(current: track)
        case .explore: await model.loadMoreExploreIfNeeded(current: track)
        }
    }

    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        TrackDetailHaptics.snap.impactOccurred(intensity: 0.7)
        // After paging, the cover goes home to the current track's row.
        if let frame = resolvedRowFrame(for: track, heroID: selection.heroID) {
            selection.sourceFrame = frame
        }
        withAnimation(TrackDetailMotion.close) {
            expanded = false
        }
        // No animation-completion hook before iOS 17: remove the overlay
        // once the fly-back has settled. The row's cover, hidden all this
        // time, takes over in the same frame at the same spot.
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
