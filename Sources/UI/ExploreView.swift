import SwiftUI
import UIKit

/// Soft tap when a stream or track is selected for playback, plus a
/// notification buzz confirming menu actions (save, copy link).
private enum ExploreHaptics {
    static let select = UIImpactFeedbackGenerator(style: .light)
    static let confirm = UINotificationFeedbackGenerator()
}

/// The Explore tab inside the home card: live channels across the platform,
/// then published tracks from all stations.
struct ExploreListView: View {
    @EnvironmentObject private var model: AppModel
    /// True while the home swipe-away gesture is engaged.
    var scrollLocked = false

    var body: some View {
        Group {
            if model.exploreTracks.isEmpty && model.exploreStreams.isEmpty && model.isLoadingExplore {
                ProgressView("Loading explore…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.exploreTracks.isEmpty && model.exploreStreams.isEmpty {
                emptyState
            } else {
                exploreList
            }
        }
        .scrollDisabled(scrollLocked)
        .task {
            await model.loadExplore()
        }
    }

    private var exploreList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !model.exploreStreams.isEmpty {
                    sectionHeader("Live now")
                    ForEach(model.exploreStreams) { stream in
                        StreamRow(
                            stream: stream,
                            isPlaying: model.player.playingKey == TrackPlayer.key(for: stream)
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !model.broadcast.state.isActive else { return }
                            ExploreHaptics.select.impactOccurred()
                            model.player.toggle(stream)
                        }
                        Divider()
                            .padding(.leading, 80)
                    }
                }

                if !model.exploreTracks.isEmpty {
                    sectionHeader("Recent tracks")
                    ForEach(model.exploreTracks) { track in
                        TrackRow(
                            track: track,
                            isPlaying: model.player.playingKey == TrackPlayer.key(for: track),
                            showsStation: true,
                            showsTags: true,
                            showsListens: false,
                            onSave: canSave(track) ? { save(track) } : nil,
                            onShare: track.webURL != nil ? { copyLink(for: track) } : nil
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !model.broadcast.state.isActive else { return }
                            ExploreHaptics.select.impactOccurred()
                            model.player.toggle(track)
                        }
                        .onAppear {
                            Task { await model.loadMoreExploreIfNeeded(current: track) }
                        }
                        Divider()
                            .padding(.leading, 80)
                    }
                }

                if model.isLoadingMoreExplore {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
        }
        .refreshable {
            await model.loadExplore()
        }
    }

    /// Tracks from other stations that aren't in the library yet.
    private func canSave(_ track: LibraryTrack) -> Bool {
        track.saved != true && track.station?.id != model.credentials?.station?.id
    }

    private func save(_ track: LibraryTrack) {
        Task {
            let saved = await model.saveTrack(track)
            ExploreHaptics.confirm.notificationOccurred(saved ? .success : .error)
        }
    }

    private func copyLink(for track: LibraryTrack) {
        guard let url = track.webURL else { return }
        UIPasteboard.general.string = url.absoluteString
        ExploreHaptics.confirm.notificationOccurred(.success)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    // Wrapped in a scroll view so pull-to-refresh can retry a failed load.
    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Nothing to explore yet")
                        .font(.headline)
                    if let error = model.exploreError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.eveningsRed)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(32)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .refreshable {
                await model.loadExplore()
            }
        }
    }
}

struct StreamRow: View {
    let stream: ExploreStream
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            TrackArtwork(url: (stream.image ?? stream.station?.image).flatMap(URL.init(string:)))
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.eveningsRed)
                    if let station = stream.station?.name, station != stream.displayName {
                        Text(station)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
