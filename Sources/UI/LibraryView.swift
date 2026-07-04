import SwiftUI

/// The library track list shown inside HomeView's draggable sheet.
struct LibraryListView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var uploads: UploadManager
    @State private var openSwipeTrackId: Int?
    @State private var trackPendingDelete: LibraryTrack?
    @State private var draftPendingDelete: Draft?

    var body: some View {
        Group {
            if model.library.isEmpty && model.isLoadingLibrary {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.library.isEmpty {
                emptyState
            } else {
                trackList
            }
        }
        .task {
            uploads.loadDrafts()
            await model.loadLibrary()
        }
    }

    /// Recordings still on this phone (offline or failed uploads).
    private var draftsSection: some View {
        VStack(spacing: 0) {
            Text("On this phone")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ForEach(uploads.drafts) { draft in
                DraftRow(
                    draft: draft,
                    isPlaying: model.player.playingKey == "draft-\(draft.id)",
                    isUploading: uploads.uploadingDraftId == draft.id,
                    uploadProgress: uploads.uploadProgress,
                    onPlay: {
                        guard !model.broadcast.state.isActive else { return }
                        model.player.toggle(url: draft.url, key: "draft-\(draft.id)")
                    },
                    onUpload: {
                        Task {
                            if await uploads.upload(draft) {
                                await model.refreshLibraryAfterBroadcast()
                            }
                        }
                    },
                    onDelete: { draftPendingDelete = draft }
                )
                Divider()
                    .padding(.leading, 20)
            }
        }
        .confirmationDialog(
            "Delete recording?",
            isPresented: Binding(
                get: { draftPendingDelete != nil },
                set: { if !$0 { draftPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: draftPendingDelete
        ) { draft in
            Button("Delete \"\(draft.title)\"", role: .destructive) {
                if model.player.playingKey == "draft-\(draft.id)" {
                    model.player.stop()
                }
                uploads.deleteDraft(draft)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This recording only exists on this phone — deleting it cannot be undone.")
        }
    }

    private var trackList: some View {
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
                if !uploads.drafts.isEmpty {
                    draftsSection
                }

                ForEach(model.library) { track in
                    SwipeToDeleteRow(
                        isEnabled: track.owner == true,
                        isOpen: openSwipeTrackId == track.id,
                        onOpenChanged: { open in
                            openSwipeTrackId = open ? track.id : nil
                        },
                        onDelete: { trackPendingDelete = track }
                    ) {
                        TrackRow(track: track, isPlaying: model.player.playingKey == TrackPlayer.key(for: track))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if openSwipeTrackId != nil {
                                    openSwipeTrackId = nil
                                    return
                                }
                                // The mic owns the audio session while broadcasting.
                                guard !model.broadcast.state.isActive else { return }
                                model.player.toggle(track)
                            }
                            .onAppear {
                                Task { await model.loadMoreLibraryIfNeeded(current: track) }
                            }
                    }
                    Divider()
                        .padding(.leading, 80)
                }

                if model.isLoadingMoreLibrary {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
        }
        .coordinateSpace(name: "libraryScroll")
        .confirmationDialog(
            "Delete recording?",
            isPresented: Binding(
                get: { trackPendingDelete != nil },
                set: { if !$0 { trackPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: trackPendingDelete
        ) { track in
            Button("Delete \"\(track.title ?? "Untitled")\"", role: .destructive) {
                openSwipeTrackId = nil
                Task { await model.deleteTrack(track) }
            }
            Button("Cancel", role: .cancel) {
                openSwipeTrackId = nil
            }
        } message: { _ in
            Text("The recording will be removed from your library.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
            Text("Your broadcasts are recorded automatically and will show up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = model.libraryError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    let isPlaying: Bool
    var showsStation = false

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title ?? "Untitled")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 4)
    }

    private var artwork: some View {
        TrackArtwork(url: track.image.flatMap(URL.init(string:)))
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsStation, let station = track.station?.name {
            parts.append(station)
        }
        if let date = track.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let duration = track.duration, duration > 0 {
            let h = duration / 3600
            let m = (duration % 3600) / 60
            parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
        }
        if let listens = track.listens, listens > 0 {
            parts.append("\(listens) listen\(listens == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

/// A recording still on the phone: play locally, upload, or delete.
struct DraftRow: View {
    let draft: Draft
    let isPlaying: Bool
    let isUploading: Bool
    let uploadProgress: Double
    let onPlay: () -> Void
    let onUpload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if isUploading {
                    ProgressView(value: uploadProgress)
                } else {
                    Text("Not in your library yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !isUploading {
                Button(action: onUpload) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Horizontal swipe-to-reveal delete for rows inside a plain ScrollView (where
/// List's swipeActions aren't available). Direction-locked so vertical
/// scrolling and the sheet drag are unaffected.
struct SwipeToDeleteRow<Content: View>: View {
    let isEnabled: Bool
    let isOpen: Bool
    let onOpenChanged: (Bool) -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @GestureState private var translation: CGFloat = 0

    private let revealWidth: CGFloat = 88

    var body: some View {
        let base: CGFloat = isOpen ? -revealWidth : 0
        let offset = min(0, max(-revealWidth - 16, base + translation))

        ZStack(alignment: .trailing) {
            if isEnabled {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.white)
                        .frame(width: revealWidth)
                        .frame(maxHeight: .infinity)
                        .background(.red)
                }
            }

            content()
                .background(Color(.systemBackground))
                .offset(x: isEnabled ? offset : 0)
                .simultaneousGesture(swipe, including: isEnabled ? .all : .subviews)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isOpen)
        }
        .clipped()
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($translation) { value, state, _ in
                // Horizontal intent only; let vertical drags scroll the list.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projected = (isOpen ? -revealWidth : 0) + value.predictedEndTranslation.width
                onOpenChanged(projected < -revealWidth / 2)
            }
    }
}

/// Cover art with distinct states: pulsing skeleton while loading, fade-in on
/// success, static waveform for tracks with no cover (or a failed load).
struct TrackArtwork: View {
    let url: URL?
    @State private var pulsing = false

    var body: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                case .failure:
                    fallback
                case .empty:
                    skeleton
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .opacity(pulsing ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
        }
    }
}
