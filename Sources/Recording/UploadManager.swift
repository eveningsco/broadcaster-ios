import Foundation
import UIKit
import UniformTypeIdentifiers

struct Draft: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    /// True for a file brought in from the Files picker (kept under
    /// `UploadManager.importsDirectory`), false for a recording made here.
    let isImported: Bool

    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// Audio files the library accepts from outside the app — the same set the
/// API server's upload filter allows (`TRACK_TYPES` in sol-api-server's
/// multer middleware) and the website's Upload Audio button offers, so a
/// pick never bounces off the server with a 415.
enum AudioImport {
    static let extensions = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "ogg"]

    /// What the Files picker is allowed to hand over. Some of these types
    /// have no constant in UniformTypeIdentifiers; they're looked up by
    /// extension, which resolves to the system's declaration (org.xiph.flac
    /// and so on) when the OS knows the format.
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "ogg"] {
            if let type = UTType(filenameExtension: ext, conformingTo: .audio) {
                types.append(type)
            }
        }
        return types
    }()

    static func accepts(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Reads "mp3, m4a, wav, …" for error copy.
    static var extensionList: String {
        extensions.map { ".\($0)" }.joined(separator: ", ")
    }
}

/// Uploads finished recordings and imported files to the library
/// (POST /v1/tracks) and manages the on-disk drafts that remain when an
/// upload fails or the phone is offline. The files themselves are the
/// store — no database.
@MainActor
final class UploadManager: ObservableObject {
    @Published private(set) var drafts: [Draft] = []
    @Published private(set) var uploadingDraftId: String?
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var lastUploadCompletedAt: Date?
    @Published var uploadError: String?
    /// A picked file that couldn't be taken in (unsupported type, unreadable);
    /// separate from `uploadError`, which means a draft exists and its upload
    /// failed.
    @Published var importError: String?

    private let api = EveningsAPI()

    /// Supplied by AppModel: returns a fresh access token (refreshing if needed).
    var freshAccessToken: (() async -> String?)?

    /// Files picked from outside the app wait here until they're in the
    /// library. A subdirectory of the recordings folder so one `loadDrafts`
    /// pass finds both kinds, while the recording-only title cleanup in
    /// `upload` can tell them apart.
    nonisolated static let importsDirectory: URL =
        RecordingController.recordingsDirectory.appendingPathComponent("imports", isDirectory: true)

    func loadDrafts() {
        let recordings = Self.drafts(in: RecordingController.recordingsDirectory, imported: false)
            .filter { $0.url.pathExtension.lowercased() == "m4a" }
        let imports = Self.drafts(in: Self.importsDirectory, imported: true)
            .filter { AudioImport.accepts($0.url) }
        drafts = (recordings + imports).sorted { $0.createdAt > $1.createdAt }
    }

    private static func drafts(in directory: URL, imported: Bool) -> [Draft] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]
        )) ?? []
        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return Draft(url: url, createdAt: values?.creationDate ?? Date(), isImported: imported)
        }
    }

    /// What went wrong with a pick, per file, so the UI can say which one.
    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case unreadable(String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let name):
                return "\"\(name)\" isn't a file type we accept. Upload one of: \(AudioImport.extensionList)."
            case .unreadable(let name, let underlying):
                return "Couldn't read \"\(name)\": \(underlying.localizedDescription)"
            }
        }
    }

    /// Copies files from the Files picker into `importsDirectory` and
    /// registers them as drafts, in the order they were picked. Each URL is
    /// security-scoped (another app's or iCloud's territory); the copy goes
    /// through a file coordinator so an iCloud file that isn't on the phone
    /// yet is downloaded first. Returns the new drafts and whatever failed.
    func importFiles(_ urls: [URL]) async -> (drafts: [Draft], errors: [ImportError]) {
        var imported: [Draft] = []
        var errors: [ImportError] = []
        for url in urls {
            let name = url.lastPathComponent
            guard AudioImport.accepts(url) else {
                errors.append(.unsupportedType(name))
                continue
            }
            do {
                let destination = try await Self.copyIntoImports(url)
                loadDrafts()
                if let draft = drafts.first(where: { $0.url == destination }) {
                    imported.append(draft)
                }
            } catch {
                errors.append(.unreadable(name, underlying: error))
            }
        }
        return (imported, errors)
    }

    /// The copy itself, off the main actor: a multi-gigabyte WAV takes a
    /// moment even on-device, and the coordinated read blocks while iCloud
    /// fetches the file.
    private nonisolated static func copyIntoImports(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: source.lastPathComponent)

            let scoped = source.startAccessingSecurityScopedResource()
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
            }

            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(
                readingItemAt: source, options: [.forUploading], error: &coordinationError
            ) { readable in
                do {
                    try fileManager.copyItem(at: readable, to: destination)
                } catch {
                    copyError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return destination
        }.value
    }

    /// "Set.wav", then "Set 2.wav", "Set 3.wav"… when the name is taken: the
    /// filename is the draft's identity and its title, so collisions must
    /// not overwrite a pending upload.
    private nonisolated static func uniqueDestination(for filename: String) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = importsDirectory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = importsDirectory
                .appendingPathComponent("\(stem) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// Returns true when the file made it into the library.
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

        // An hour-long set is a big upload; if the screen locks the app
        // suspends and the socket dies. Keep the screen awake, and buy grace
        // time if the user briefly leaves.
        UIApplication.shared.isIdleTimerDisabled = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "library-upload")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            // Recordings come out of AVAudioFile with the moov atom at the
            // end; remux it to the front so the server can read the duration
            // from a stream (and web playback starts immediately). Only an
            // .m4a needs (or survives) this; other formats go up as they
            // are. Fall back to the raw file if the remux fails.
            let isM4A = draft.url.pathExtension.lowercased() == "m4a"
            let streamableURL = isM4A
                ? ((try? await Faststart.makeStreamable(draft.url)) ?? draft.url)
                : draft.url
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
            // (including extension); give it the clean display title. For
            // recordings that also turns the filename-safe "3.42 PM" back
            // into "3:42 PM" — an imported "Mix 1.2.mp3" keeps its dots.
            let cleanTitle = draft.isImported
                ? draft.title
                : draft.title.replacingOccurrences(
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
