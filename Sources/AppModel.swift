import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isLoggingIn = false
    @Published var loginError: String?

    @Published private(set) var library: [LibraryTrack] = []
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var isLoadingMoreLibrary = false
    @Published var libraryError: String?

    @Published private(set) var exploreTracks: [LibraryTrack] = []
    @Published private(set) var exploreStreams: [ExploreStream] = []
    @Published private(set) var isLoadingExplore = false
    @Published private(set) var isLoadingMoreExplore = false
    @Published var exploreError: String?

    /// Server page size for /v1/library and /v1/explore (their maximum); a
    /// short page means the end.
    private let libraryPageSize = 100
    private var libraryPage = 0
    private var libraryHasMore = true
    private var explorePage = 0
    private var exploreHasMore = true

    let broadcast = BroadcastController()
    let player = TrackPlayer()
    let recorder: RecordingController
    let uploads = UploadManager()
    private let api = EveningsAPI()

    init() {
        credentials = Keychain.load()
        recorder = RecordingController(broadcast: broadcast)
        uploads.freshAccessToken = { [weak self] in
            await self?.ensureFreshSession()
            return self?.credentials?.accessToken
        }
        recorder.onAutoStopped = { [weak self] url in
            if let url {
                self?.handleFinishedRecording(url)
            }
        }
        uploads.loadDrafts()
    }

    /// A recording just ended: register it as a draft and try to upload it.
    func handleFinishedRecording(_ url: URL) {
        uploads.loadDrafts()
        guard let draft = uploads.drafts.first(where: { $0.url == url }) else { return }
        Task {
            if await uploads.upload(draft) {
                await refreshLibraryAfterBroadcast()
            }
        }
    }

    var isLoggedIn: Bool { credentials != nil }

    func login(email: String, password: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            let deviceId = await UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            let deviceName = await UIDevice.current.name
            let response = try await api.connect(
                email: email,
                password: password,
                deviceId: deviceId,
                deviceName: deviceName
            )
            let credentials = Credentials(
                accessToken: response.accessToken,
                accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
                refreshToken: response.refreshToken,
                streamKey: response.streamKey,
                channelId: response.channelId,
                station: response.station
            )
            try Keychain.save(credentials)
            self.credentials = credentials
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() {
        _ = recorder.stop()
        broadcast.stop()
        player.stop()
        Keychain.clear()
        credentials = nil
        library = []
        exploreTracks = []
        exploreStreams = []
    }

    func loadExplore() async {
        guard credentials != nil, !isLoadingExplore else { return }
        isLoadingExplore = true
        defer { isLoadingExplore = false }
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return }
        do {
            async let tracks = api.exploreTracks(accessToken: token)
            async let streams = api.exploreStreams(accessToken: token)
            let (loadedTracks, loadedStreams) = try await (tracks, streams)
            exploreTracks = loadedTracks
            exploreStreams = loadedStreams
            explorePage = 0
            exploreHasMore = loadedTracks.count >= libraryPageSize
            exploreError = nil
        } catch {
            exploreError = error.localizedDescription
        }
    }

    func loadMoreExploreIfNeeded(current track: LibraryTrack) async {
        guard exploreHasMore, !isLoadingExplore, !isLoadingMoreExplore,
              track.id == exploreTracks.last?.id else { return }
        isLoadingMoreExplore = true
        defer { isLoadingMoreExplore = false }
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return }
        do {
            let nextPage = try await api.exploreTracks(accessToken: token, page: explorePage + 1)
            explorePage += 1
            exploreHasMore = nextPage.count >= libraryPageSize
            let known = Set(exploreTracks.map(\.id))
            exploreTracks.append(contentsOf: nextPage.filter { !known.contains($0.id) })
        } catch {
            exploreError = error.localizedDescription
        }
    }

    func loadLibrary() async {
        guard credentials != nil, !isLoadingLibrary else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return }
        do {
            let firstPage = try await api.library(accessToken: token)
            library = firstPage
            libraryPage = 0
            libraryHasMore = firstPage.count >= libraryPageSize
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// Infinite scroll: fetch the next page when the given track is the last
    /// one currently loaded.
    func loadMoreLibraryIfNeeded(current track: LibraryTrack) async {
        guard libraryHasMore, !isLoadingLibrary, !isLoadingMoreLibrary,
              track.id == library.last?.id else { return }
        isLoadingMoreLibrary = true
        defer { isLoadingMoreLibrary = false }
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return }
        do {
            let nextPage = try await api.library(accessToken: token, page: libraryPage + 1)
            libraryPage += 1
            libraryHasMore = nextPage.count >= libraryPageSize
            // Dedupe in case the list shifted between page fetches.
            let known = Set(library.map(\.id))
            library.append(contentsOf: nextPage.filter { !known.contains($0.id) })
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// Returns true on success so the UI can keep the row when deletion fails.
    func deleteTrack(_ track: LibraryTrack) async -> Bool {
        if player.playingKey == TrackPlayer.key(for: track) {
            player.stop()
        }
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return false }
        do {
            try await api.deleteTrack(id: track.id, accessToken: token)
            library.removeAll { $0.id == track.id }
            return true
        } catch {
            libraryError = error.localizedDescription
            return false
        }
    }

    /// After a broadcast ends the recording finalizes asynchronously (S3 upload +
    /// webhook), so poll briefly until a new track shows up.
    func refreshLibraryAfterBroadcast() async {
        let previousNewestId = library.first?.id
        for _ in 0..<5 {
            await loadLibrary()
            if library.first?.id != previousNewestId { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    /// Refresh the access token (and stream key) if stale. Call before going live.
    func ensureFreshSession() async {
        guard var credentials, !credentials.accessTokenIsFresh else { return }
        do {
            let response = try await api.refresh(refreshToken: credentials.refreshToken)
            credentials.accessToken = response.accessToken
            credentials.accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
            credentials.streamKey = response.streamKey
            credentials.channelId = response.channelId ?? credentials.channelId
            credentials.station = response.station ?? credentials.station
            try Keychain.save(credentials)
            self.credentials = credentials
        } catch APIError.invalidCredentials {
            // Refresh token expired or revoked -- force a fresh login.
            logout()
        } catch {
            // Network hiccup: keep the session; the stream key rarely rotates.
        }
    }

    func fetchStatus() async -> StreamStatus? {
        guard let channelId = credentials?.channelId else { return nil }
        return try? await api.status(channelId: channelId)
    }
}
