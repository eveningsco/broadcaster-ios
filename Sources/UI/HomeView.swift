import SwiftUI
import UIKit

/// Shared feedback generator, kept warm from the drag so the snap haptic
/// fires with no latency at the commit point.
private enum HomeHaptics {
    static let snap = UIImpactFeedbackGenerator(style: .medium)
    /// Soft tap for the bottom bar's play/pause control, matching row selection.
    static let tap = UIImpactFeedbackGenerator(style: .light)
}

/// Home layout: the livestream stage (BroadcastView) sits at the back, with
/// the library floating over it as a rounded card. Swiping the library away to
/// the right reveals the stage — that's how you enter livestream mode; swiping
/// back left (or ending a broadcast) returns to the library.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    // Screenshot mode starts with the stage revealed for the stage scenes.
    @State private var libraryShown = !(ScreenshotMode.scene?.showsStage ?? false)
    @State private var dragTranslation: CGFloat = 0
    /// True while a finger is scrubbing the mini player's waveform, so the
    /// swipe-away gesture stays out of the way.
    @State private var isScrubbing = false
    /// Deferred audio-session work scheduled after a transition settles.
    @State private var audioTransitionTask: Task<Void, Never>?
    /// Pull-down-to-search over the library.
    @State private var searchActive = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    /// Whether the library list is scrolled to its top; a downward pull on
    /// the list only means "search" when it starts from the top.
    @State private var listAtTop = true

    enum CardTab {
        case library
        case explore
    }
    @State private var cardTab: CardTab = ScreenshotMode.scene == .explore ? .explore : .library
    /// The account sheet (station photo, name, sign out) from the header gear.
    @State private var showingAccount = ScreenshotMode.scene == .account
    /// What a horizontal drag is moving: the whole card off the stage, or
    /// the tab strip inside the card (library ↔ explore). Locked when the
    /// drag engages so a mid-gesture direction reversal doesn't switch jobs.
    private enum DragRole {
        case stage
        case tab
    }
    @State private var dragRole: DragRole = .stage
    @State private var tabDragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let baseOffset: CGFloat = libraryShown ? 0 : width
            let offset = min(max(baseOffset + dragTranslation, 0), width)
            // 0 = library covering the stage, 1 = stage fully revealed.
            let progress = width > 0 ? offset / width : 0

            ZStack {
                Color.black

                BroadcastView(
                    broadcast: model.broadcast,
                    recorder: model.recorder,
                    uploads: model.uploads,
                    stageVisible: !libraryShown,
                    revealProgress: progress,
                    onBack: {
                        HomeHaptics.tap.impactOccurred()
                        // Warm the generator so the snap that fires when
                        // libraryShown flips lands with no latency.
                        HomeHaptics.snap.prepare()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            libraryShown = true
                        }
                    }
                )
                .padding(.top, geometry.safeAreaInsets.top)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
                .background(Color.eveningsStage)
                // The stage brightens as the card slides away — depth without
                // any scaling, so the screen edges never move.
                .opacity(0.7 + 0.3 * progress)

                libraryLayer(safeArea: geometry.safeAreaInsets, width: width)
                    .offset(x: offset)
            }
            .ignoresSafeArea()
            .simultaneousGesture(swipeAway(width: width))
        }
        // The keyboard overlays the content: without this the geometry
        // shrinks when it appears and the whole page shifts up.
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showingAccount) {
            AccountSheet()
        }
        .onChange(of: libraryShown) { shown in
            HomeHaptics.snap.impactOccurred(intensity: 0.9)
            // Pause (don't stop) so the mini player is still there, loaded,
            // when the library comes back; going live/recording still stops
            // it for real.
            if !shown {
                model.player.pause()
            }
            // Live level meter while the stage is showing (mic check before
            // going live); release the mic when browsing. Starting/stopping
            // capture blocks the main thread long enough to drop frames, so
            // wait for the slide animation to settle first.
            audioTransitionTask?.cancel()
            audioTransitionTask = Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                if shown {
                    model.broadcast.stopMonitoring()
                } else {
                    model.broadcast.startMonitoring()
                }
            }
        }
        .onChange(of: cardTab) { _ in
            HomeHaptics.tap.impactOccurred()
        }
        .onChange(of: model.broadcast.state.isActive) { active in
            if !active {
                libraryShown = true
                Task { await model.refreshLibraryAfterBroadcast() }
            }
        }
        // A recording upload just landed in the library — show it.
        .onReceive(model.uploads.$lastUploadCompletedAt) { completedAt in
            if completedAt != nil {
                libraryShown = true
            }
        }
    }

    /// The library card plus the go-live pill, with the stage's backdrop
    /// showing through the margins so the card reads as a layer on top.
    private func libraryLayer(safeArea: EdgeInsets, width: CGFloat) -> some View {
        VStack(spacing: 20) {
            libraryCard(safeArea: safeArea, width: width)

            HomeBottomBar(player: model.player, isScrubbing: $isScrubbing) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    libraryShown = false
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, safeArea.bottom + 8)
    }

    /// Rows scroll edge to edge inside the card, fading out under the header
    /// and again just above the card's rounded bottom.
    private func libraryCard(safeArea: EdgeInsets, width: CGFloat) -> some View {
        // Both lists live side by side in a strip twice the card's width;
        // the active tab picks the resting offset and a tab drag tracks the
        // finger between them, hard-stopped at either end.
        let tabBase: CGFloat = cardTab == .library ? 0 : -width
        let tabOffset = min(max(tabBase + tabDragTranslation, -width), 0)
        let listsLocked = dragTranslation != 0 || tabDragTranslation != 0
        return HStack(spacing: 0) {
            LibraryListView(
                uploads: model.uploads,
                scrollLocked: listsLocked,
                searchQuery: searchActive ? searchQuery : "",
                listAtTop: $listAtTop
            )
            .frame(width: width)
            ExploreListView(scrollLocked: listsLocked)
                .frame(width: width)
        }
        .offset(x: tabOffset)
        .frame(width: width, alignment: .leading)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        cardTabTitle("Library", tab: .library)
                        cardTabTitle("Explore", tab: .explore)
                        Spacer(minLength: 0)
                        // Both icons carry 44pt hit targets, so they sit
                        // flush; the header is only a few points wider than
                        // its content and a 16pt gap here wrapped "Library".
                        HStack(spacing: 0) {
                            AccountButton { showingAccount = true }
                            LoopButton(player: model.player)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, safeArea.top + 24)

                    if searchActive {
                        searchField
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 12)
                .background {
                    // Bleeds below the header so rows fade out before they
                    // reach the title (black on the dark card). Holds solid
                    // through most of its height before fading.
                    LinearGradient(
                        stops: [
                            .init(color: Color(.systemBackground), location: 0),
                            .init(color: Color(.systemBackground), location: 0.6),
                            .init(color: Color(.systemBackground).opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .padding(.bottom, -48)
                }
                .contentShape(Rectangle())
                // Pulling down on the header reveals the search field. The
                // header sits outside the scroll view, so this doesn't fight
                // list scrolling; the vertical-dominance check keeps it out
                // of the horizontal swipe-away's lane.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard !searchActive, cardTab == .library,
                                  value.translation.height > 40,
                                  value.translation.height > abs(value.translation.width) else { return }
                            revealSearch()
                        }
                )
            }
            // Let the last row scroll up out of the bottom fade.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 32)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 56)
                .allowsHitTesting(false)
            }
            .background(Color(.systemBackground))
            // Full-bleed at the top; only the bottom corners are rounded so
            // the card looks anchored to the top of the screen.
            .clipShape(UnevenRoundedRectangle(
                cornerRadii: .init(bottomLeading: 40, bottomTrailing: 40),
                style: .continuous
            ))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            // Pulling down anywhere on the card while the list is at its top
            // reveals the search (the header gesture handles pulls when the
            // list is scrolled deep).
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !searchActive, listAtTop, cardTab == .library,
                              value.translation.height > 48,
                              value.translation.height > abs(value.translation.width) else { return }
                        revealSearch()
                    }
            )
    }

    /// Header tab title; the active one reads in ink, the other recedes.
    private func cardTabTitle(_ label: String, tab: CardTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                cardTab = tab
            }
        } label: {
            Text(label)
                .font(.custom("ETBembo-SemiBoldOSF", size: 34))
                .foregroundStyle(cardTab == tab ? Color.primary : Color(.systemGray2))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }


    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your library", text: $searchQuery)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Button {
                dismissSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.08)))
    }

    private func revealSearch() {
        guard !searchActive else { return }
        HomeHaptics.snap.impactOccurred(intensity: 0.6)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            searchActive = true
        }
        // Focus after the field exists in the hierarchy.
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func dismissSearch() {
        searchQuery = ""
        searchFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            searchActive = false
        }
    }

    /// Whole-screen horizontal drag, direction-locked so vertical list
    /// scrolling is untouched — but once a horizontal drag engages it stays
    /// engaged, tracking the finger 1:1; the spring only runs on release.
    /// A rightward drag on the library slides the card off to reveal the
    /// stage (and a leftward drag on the stage brings it back); any other
    /// horizontal drag slides between the card's Library and Explore tabs.
    private func swipeAway(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isScrubbing {
                    dragTranslation = 0
                    tabDragTranslation = 0
                    return
                }
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                let engaged = dragTranslation != 0 || tabDragTranslation != 0
                guard horizontal || engaged else { return }
                if !engaged {
                    HomeHaptics.snap.prepare()
                    if !libraryShown || (cardTab == .library && value.translation.width > 0) {
                        dragRole = .stage
                    } else {
                        dragRole = .tab
                    }
                }
                switch dragRole {
                case .stage:
                    dragTranslation = value.translation.width
                case .tab:
                    tabDragTranslation = value.translation.width
                }
            }
            .onEnded { value in
                // Only commit if this gesture actually moved something (a
                // waveform scrub keeps both translations pinned at 0).
                let projected = value.predictedEndTranslation.width
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    switch dragRole {
                    case .stage where dragTranslation != 0:
                        if libraryShown, projected > width / 3 {
                            libraryShown = false
                        } else if !libraryShown, projected < -width / 3 {
                            libraryShown = true
                        }
                    case .tab where tabDragTranslation != 0:
                        if cardTab == .library, projected < -width / 3 {
                            cardTab = .explore
                        } else if cardTab == .explore, projected > width / 3 {
                            cardTab = .library
                        }
                    default:
                        break
                    }
                    dragTranslation = 0
                    tabDragTranslation = 0
                }
            }
    }
}

/// Opens the account sheet; sits beside the loop toggle in the card header
/// and shares its 44pt hit target and muted ink.
struct AccountButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.body.weight(.medium))
                .foregroundStyle(Color(.systemGray))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
    }
}

/// Toggles looping for the currently selected track; lit in the brand red
/// while that track loops, dimmed when nothing is loaded.
struct LoopButton: View {
    @ObservedObject var player: TrackPlayer

    var body: some View {
        Button {
            player.toggleLooping()
        } label: {
            Image(systemName: "repeat")
                .font(.body.weight(.medium))
                .foregroundStyle(player.isLoopingCurrent ? Color.eveningsRed : Color(.systemGray))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(player.playingKey == nil ? 0.4 : 1)
    }
}

/// The go-live circle with, while a track is playing, a mini player to its
/// right (artwork, title, pause). Observes the player directly so it appears
/// and disappears with playback.
struct HomeBottomBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var player: TrackPlayer
    @Binding var isScrubbing: Bool
    let goLive: () -> Void

    @StateObject private var waveform = WaveformLoader()

    /// One height for the circle and the player so they always line up.
    private let barHeight: CGFloat = 64

    private struct NowPlaying {
        let title: String
        let station: String?
        let imageURL: URL?
        let audioURL: URL?
    }

    private var nowPlaying: NowPlaying? {
        guard let key = player.playingKey else { return nil }
        if let track = model.library.first(where: { TrackPlayer.key(for: $0) == key })
            ?? model.exploreTracks.first(where: { TrackPlayer.key(for: $0) == key }) {
            return NowPlaying(
                title: track.title ?? "Untitled",
                station: track.station?.name,
                imageURL: (track.image ?? track.station?.image).flatMap(URL.init(string:)),
                audioURL: track.audioURL
            )
        }
        if let stream = model.exploreStreams.first(where: { TrackPlayer.key(for: $0) == key }) {
            // Live stream: endless, so no audio file to draw a waveform from.
            let station = stream.station?.name
            return NowPlaying(
                title: stream.displayName,
                station: station == stream.displayName ? nil : station,
                imageURL: (stream.image ?? stream.station?.image).flatMap(URL.init(string:)),
                audioURL: nil
            )
        }
        if let draft = model.uploads.drafts.first(where: { "draft-\($0.id)" == key }) {
            return NowPlaying(title: draft.title, station: nil, imageURL: nil, audioURL: draft.url)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: goLive) {
                Circle()
                    .fill(Color.eveningsRed)
                    .frame(width: barHeight, height: barHeight)
            }
            .buttonStyle(.plain)

            if let nowPlaying {
                HStack(spacing: 12) {
                    TrackArtwork(url: nowPlaying.imageURL)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if player.isPaused {
                        // Paused: the scrubber gives way to what's queued up.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(nowPlaying.title)
                                .font(.social(.footnote, weight: .medium))
                                .lineLimit(1)
                            if let station = nowPlaying.station {
                                Text(station)
                                    .font(.social(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    } else {
                        PlayingWaveform(
                            levels: waveform.levels,
                            progress: player.progress,
                            onScrub: { player.seek(toFraction: $0) },
                            isScrubbing: $isScrubbing
                        )
                        .transition(.opacity)
                    }
                    Button {
                        HomeHaptics.tap.impactOccurred()
                        if player.isPaused {
                            player.resume()
                        } else {
                            player.pause()
                        }
                    } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
                .background(Color(.systemBackground))
                // Concentric with the cover art: its 8pt radius plus the
                // 12pt inset around it.
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: player.isPaused)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .task(id: player.playingKey) {
                    if let key = player.playingKey {
                        waveform.load(key: key, url: nowPlaying.audioURL)
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.playingKey)
    }
}

/// The playing track's waveform doubling as a scrubber: capsule bars sized
/// from the audio's per-bucket levels (flat while they're still computing),
/// bars behind the playhead render brighter, and dragging (or tapping) across
/// the bars seeks on release.
struct PlayingWaveform: View {
    /// Normalized 0...1 amplitude per bar; nil while still computing.
    let levels: [Float]?
    let progress: Double
    let onScrub: (Double) -> Void
    @Binding var isScrubbing: Bool

    /// Position under the finger while scrubbing, previewed before the seek.
    @State private var scrubFraction: Double?
    /// Bar index last crossed by the finger; a tick fires on each new bar so
    /// scrubbing feels like a zipper.
    @State private var lastTickedBar: Int?

    private static let tick = UISelectionFeedbackGenerator()

    private var barCount: Int { levels?.count ?? 24 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let displayed = scrubFraction ?? progress

            ZStack(alignment: .leading) {
                bars.opacity(0.25)
                // Continuous playhead: a bright copy masked to the exact
                // progress width, so even the first seconds of a long track
                // are visible (per-bar coloring hid anything under ~2%).
                bars
                    .opacity(0.9)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(3, displayed * width))
                    }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            Self.tick.prepare()
                        }
                        isScrubbing = true
                        let fraction = min(max(value.location.x / width, 0), 1)
                        scrubFraction = fraction
                        let bar = min(barCount - 1, Int(fraction * Double(barCount)))
                        if bar != lastTickedBar {
                            if lastTickedBar != nil {
                                Self.tick.selectionChanged()
                                Self.tick.prepare()
                            }
                            lastTickedBar = bar
                        }
                    }
                    .onEnded { value in
                        onScrub(min(max(value.location.x / width, 0), 1))
                        scrubFraction = nil
                        lastTickedBar = nil
                        isScrubbing = false
                    }
            )
        }
    }

    private var bars: some View {
        HStack(spacing: 0) {
            ForEach(0..<barCount, id: \.self) { index in
                let height = levels.map { 6 + 22 * CGFloat($0[index]) } ?? 5
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: height)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: levels)
    }
}
