import SwiftUI

/// The Explore tab inside HomeView's sheet: live channels across the platform,
/// then published tracks from all stations.
struct ExploreListView: View {
    @EnvironmentObject private var model: AppModel

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
        .task {
            await model.loadExplore()
        }
    }

    private var exploreList: some View {
        ScrollView {
            // Anchor for HomeView's at-top detection (drives sheet dragging).
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LibraryScrollOffsetKey.self,
                    value: proxy.frame(in: .named("libraryScroll")).minY
                )
            }
            .frame(height: 0)

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
                            model.player.toggle(stream)
                        }
                        Divider()
                            .padding(.leading, 20)
                    }
                }

                if !model.exploreTracks.isEmpty {
                    sectionHeader("Recent tracks")
                    ForEach(model.exploreTracks) { track in
                        TrackRow(
                            track: track,
                            isPlaying: model.player.playingKey == TrackPlayer.key(for: track),
                            showsStation: true
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !model.broadcast.state.isActive else { return }
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
        .coordinateSpace(name: "libraryScroll")
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing to explore yet")
                .font(.headline)
            if let error = model.exploreError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                    if let listeners = stream.subscribers, listeners > 0 {
                        Text("\(listeners) listening")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let station = stream.station?.name, station != stream.displayName {
                        Text(station)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 4)
    }
}
