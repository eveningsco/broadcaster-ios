import SwiftUI
import UIKit

/// Soft tap when a track is selected for playback, plus a notification buzz
/// confirming menu actions (remove, copy link).
private enum LibraryHaptics {
    static let select = UIImpactFeedbackGenerator(style: .light)
    static let confirm = UINotificationFeedbackGenerator()
}

/// The library track list shown on HomeView's library page.
struct LibraryListView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var uploads: UploadManager
    /// True while the home swipe-away gesture is engaged, so the list can't
    /// scroll vertically underneath the horizontal drag.
    var scrollLocked = false
    /// Keyword filter over titles and station names; empty shows everything.
    var searchQuery = ""
    /// Reports whether the list is scrolled to its top (drives pull-to-search).
    @Binding var listAtTop: Bool
    @State private var trackPendingDelete: LibraryTrack?
    @State private var trackToEdit: LibraryTrack?
    /// Screenshot mode's `edit` scenes open the editor on the first track.
    @State private var trackToEditAudio: LibraryTrack? =
        ScreenshotMode.scene?.opensEditor == true ? ScreenshotFixtures.library.first : nil
    /// The track detail card (owned by HomeView, which hosts the overlay);
    /// tapping a cover sets it.
    @Binding var detail: TrackDetailSelection?
    /// True while the detail card's cover has flown out of its row.
    var heroExpanded = false
    @State private var draftPendingDelete: Draft?

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    private var filteredLibrary: [LibraryTrack] {
        guard !trimmedQuery.isEmpty else { return model.library }
        return model.library.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(trimmedQuery)
                || ($0.station?.name ?? "").localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredDrafts: [Draft] {
        guard !trimmedQuery.isEmpty else { return uploads.drafts }
        return uploads.drafts.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

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
        .scrollDisabled(scrollLocked)
        .task {
            uploads.loadDrafts()
            await model.loadLibrary()
        }
    }

    private func remove(_ track: LibraryTrack) {
        Task {
            let removed = await model.removeSavedTrack(track)
            LibraryHaptics.confirm.notificationOccurred(removed ? .success : .error)
        }
    }

    private func copyLink(for track: LibraryTrack) {
        guard let url = track.webURL else { return }
        UIPasteboard.general.string = url.absoluteString
        LibraryHaptics.confirm.notificationOccurred(.success)
    }

    /// Recordings still on this phone (offline or failed uploads).
    private var draftsSection: some View {
        VStack(spacing: 0) {
            Text("On this phone")
                .font(.social(.subheadline, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ForEach(filteredDrafts) { draft in
                DraftRow(
                    draft: draft,
                    isPlaying: model.player.playingKey == "draft-\(draft.id)",
                    isUploading: uploads.uploadingDraftId == draft.id,
                    uploadProgress: uploads.uploadProgress,
                    onPlay: {
                        guard !model.broadcast.state.isActive else { return }
                        LibraryHaptics.select.impactOccurred()
                        model.player.toggle(url: draft.url, key: "draft-\(draft.id)", title: draft.title)
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
            LazyVStack(spacing: 0) {
                // At-top sentinel: visible only while the list is at (or
                // rubber-banding past) its top.
                Color.clear
                    .frame(height: 1)
                    .onAppear { listAtTop = true }
                    .onDisappear { listAtTop = false }

                if !filteredDrafts.isEmpty {
                    draftsSection
                }

                ForEach(filteredLibrary) { track in
                    let heroID = TrackDetailSelection.heroID(list: "library", track: track)
                    TrackRow(
                        track: track,
                        isPlaying: model.player.playingKey == TrackPlayer.key(for: track),
                        onEdit: track.owner == true ? { trackToEdit = track } : nil,
                        // Audio editing (trim + tempo) is open to saved
                        // tracks from other stations too — the result
                        // uploads as your own private track (a remix),
                        // leaving the original untouched.
                        onEditAudio: track.audioURL != nil ? {
                            // The mic owns the audio session while broadcasting.
                            guard !model.broadcast.state.isActive else { return }
                            trackToEditAudio = track
                        } : nil,
                        onDelete: track.owner == true ? { trackPendingDelete = track } : nil,
                        onRemove: track.owner != true ? { remove(track) } : nil,
                        onShare: track.webURL != nil ? { copyLink(for: track) } : nil,
                        onOpenDetails: { coverFrame in
                            LibraryHaptics.select.impactOccurred()
                            detail = TrackDetailSelection(track: track, heroID: heroID, sourceFrame: coverFrame)
                        },
                        heroID: heroID,
                        coverHidden: heroExpanded && detail?.heroID == heroID
                    )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // The mic owns the audio session while broadcasting.
                            guard !model.broadcast.state.isActive else { return }
                            LibraryHaptics.select.impactOccurred()
                            model.player.toggle(track)
                        }
                        .onAppear {
                            Task { await model.loadMoreLibraryIfNeeded(current: track) }
                        }
                    Divider()
                        .padding(.leading, 80)
                }

                if !trimmedQuery.isEmpty, filteredLibrary.isEmpty, filteredDrafts.isEmpty {
                    Text("No tracks match \"\(trimmedQuery)\"")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }

                if model.isLoadingMoreLibrary {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
        }
        .refreshable {
            uploads.loadDrafts()
            await model.loadLibrary()
        }
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
                Task { await model.deleteTrack(track) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording will be removed from your library.")
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $trackToEditAudio) { track in
            AudioEditSheet(track: track)
        }
    }

    // Wrapped in a scroll view so pull-to-refresh can retry a failed load.
    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No recordings yet")
                        .font(.social(.headline, weight: .bold))
                    Text("Your broadcasts are recorded automatically and will show up here.")
                        .font(.social(.footnote))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let error = model.libraryError {
                        Text(error)
                            .font(.social(.footnote))
                            .foregroundStyle(Color.eveningsRed)
                    }
                }
                .padding(32)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .refreshable {
                uploads.loadDrafts()
                await model.loadLibrary()
            }
        }
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    let isPlaying: Bool
    var showsStation = false
    var showsTags = false
    var showsListens = true
    var onEdit: (() -> Void)?
    var onEditAudio: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSave: (() -> Void)?
    var onRemove: (() -> Void)?
    var onShare: (() -> Void)?
    /// Tapping the cover opens the track detail card; the rest of the row
    /// still toggles playback (the list's tap gesture).
    /// Passed the cover's frame in `HeroSpace`, where the card's cover
    /// flies out from.
    var onOpenDetails: ((CGRect) -> Void)?
    /// Hero transition into the detail card: the cover publishes its frame
    /// under `heroID` (`CoverFramesKey`) and hides while the card's copy is
    /// up, so there's one visible element throughout.
    var heroID: String?
    var coverHidden = false
    @State private var coverFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 12) {
            if let onOpenDetails {
                Button(action: { onOpenDetails(coverFrame) }) {
                    artwork
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Track details")
            } else {
                artwork
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title ?? "Untitled")
                    .font(.social(.body, weight: .medium))
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.social(.footnote))
                    .foregroundStyle(.secondary)
                if showsTags, !visibleTags.isEmpty {
                    Text(visibleTags.map { "#\($0)" }.joined(separator: " "))
                        .font(.social(.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if onEdit != nil || onEditAudio != nil || onDelete != nil || onSave != nil || onRemove != nil || onShare != nil {
                Menu {
                    if let onSave {
                        Button(action: onSave) {
                            Label("Save to Library", systemImage: "square.and.arrow.down")
                        }
                    }
                    if let onShare {
                        Button(action: onShare) {
                            Label("Share Link", systemImage: "link")
                        }
                    }
                    if let onEdit {
                        Button(action: onEdit) {
                            Label("Edit Details", systemImage: "pencil")
                        }
                    }
                    if let onEditAudio {
                        Button(action: onEditAudio) {
                            Label("Edit Audio", systemImage: "waveform")
                        }
                    }
                    if let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            Label("Remove from Library", systemImage: "minus.circle")
                        }
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.systemGray))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Tags that exist for bookkeeping (not curation) stay hidden.
    private static let hiddenTags: Set<String> = ["uploaded-to-mixcloud"]

    private var visibleTags: [String] {
        (track.tags ?? []).filter {
            !Self.hiddenTags.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // No track cover -> the station's image (matches how the server
        // decorates broadcast recordings).
        let base = TrackArtwork(url: (track.image ?? track.station?.image).flatMap(URL.init(string:)))
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        if let heroID {
            base
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: CoverFramesKey.self,
                        value: [heroID: geometry.frame(in: .named(HeroSpace.name))]
                    )
                })
                .onPreferenceChange(CoverFramesKey.self) { frames in
                    if let frame = frames[heroID] { coverFrame = frame }
                }
                .opacity(coverHidden ? 0 : 1)
        } else {
            base
        }
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
        if showsListens, let listens = track.listens, listens > 0 {
            parts.append("\(listens) listen\(listens == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

/// Edits a track's title and description via PATCH /v1/tracks/:id.
struct EditTrackSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: LibraryTrack
    @State private var title: String
    @State private var details: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(track: LibraryTrack) {
        self.track = track
        _title = State(initialValue: track.title ?? "")
        _details = State(initialValue: track.description ?? "")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Description") {
                    TextEditor(text: $details)
                        .frame(minHeight: 120)
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.social(.footnote))
                            .foregroundStyle(Color.eveningsRed)
                    }
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            // The server rejects an empty title.
                            .disabled(trimmedTitle.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            let saved = await model.updateTrack(track, title: trimmedTitle, description: details)
            isSaving = false
            if saved {
                dismiss()
            } else {
                saveError = model.libraryError ?? "Couldn't save changes."
            }
        }
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
                    .font(.social(.body, weight: .medium))
                    .lineLimit(1)
                if isUploading {
                    ProgressView(value: uploadProgress)
                } else {
                    Text("Not in your library yet")
                        .font(.social(.footnote))
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

/// Cover art with distinct states: pulsing skeleton while loading, fade-in on
/// success, static waveform for tracks with no cover (or a failed load).
struct TrackArtwork: View {
    let url: URL?
    /// Size of the waveform glyph in the no-cover state; the detail sheet's
    /// large cover passes a bigger one so it doesn't float as a speck.
    var symbolFont: Font = .body
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
                .font(symbolFont)
                .foregroundStyle(.secondary)
        }
    }
}
