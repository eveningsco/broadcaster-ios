import Foundation

struct Draft: Identifiable, Equatable {
    let url: URL
    let createdAt: Date

    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// Uploads finished recordings to the library (POST /v1/tracks) and manages
/// the on-disk drafts that remain when an upload fails or the phone is
/// offline. The files themselves are the store — no database.
@MainActor
final class UploadManager: ObservableObject {
    @Published private(set) var drafts: [Draft] = []
    @Published private(set) var uploadingDraftId: String?
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var lastUploadCompletedAt: Date?
    @Published var uploadError: String?

    private let api = EveningsAPI()

    /// Supplied by AppModel: returns a fresh access token (refreshing if needed).
    var freshAccessToken: (() async -> String?)?

    func loadDrafts() {
        let directory = RecordingController.recordingsDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        drafts = contents
            .filter { $0.pathExtension == "m4a" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return Draft(url: url, createdAt: created)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns true when the recording made it into the library.
    @discardableResult
    func upload(_ draft: Draft) async -> Bool {
        guard uploadingDraftId == nil else { return false }
        uploadingDraftId = draft.id
        uploadProgress = 0
        uploadError = nil
        defer { uploadingDraftId = nil }

        guard let token = await freshAccessToken?() else {
            uploadError = "Not signed in."
            return false
        }

        do {
            // Remux moov-to-front so the server can read the duration from a
            // stream (and web playback starts immediately). Fall back to the
            // raw file if the remux fails for any reason.
            let streamableURL = (try? await Faststart.makeStreamable(draft.url)) ?? draft.url
            defer {
                if streamableURL != draft.url {
                    try? FileManager.default.removeItem(at: streamableURL)
                }
            }

            let uploaded = try await api.uploadTrack(
                fileURL: streamableURL,
                filename: draft.url.lastPathComponent,
                accessToken: token
            ) { [weak self] progress in
                Task { @MainActor in self?.uploadProgress = progress }
            }

            // The server titles the track with the uploaded filename
            // (including extension); give it the clean display title, turning
            // the filename-safe "3.42 PM" back into "3:42 PM".
            let cleanTitle = draft.title.replacingOccurrences(
                of: #"(\d)\.(\d)"#,
                with: "$1:$2",
                options: .regularExpression
            )
            try? await api.updateTrackTitle(id: uploaded.id, title: cleanTitle, accessToken: token)

            try? FileManager.default.removeItem(at: draft.url)
            loadDrafts()
            lastUploadCompletedAt = Date()
            return true
        } catch {
            uploadError = error.localizedDescription
            loadDrafts()
            return false
        }
    }

    func deleteDraft(_ draft: Draft) {
        try? FileManager.default.removeItem(at: draft.url)
        loadDrafts()
    }
}
