import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isLoggingIn = false
    @Published var loginError: String?
    @Published private(set) var isSigningUp = false
    @Published var signUpError: String?

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
        recorder = RecordingController(broadcast: broadcast)
        if let scene = ScreenshotMode.scene {
            applyScreenshotScene(scene)
        } else {
            credentials = Keychain.load()
        }
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

    /// Screenshot mode (debug launches with `-screenshot <scene>`): stand in
    /// fixture data for the Keychain and the API so every screen renders
    /// without an account. The load* methods below become no-ops.
    private func applyScreenshotScene(_ scene: ScreenshotMode.Scene) {
        guard scene.isSignedIn else { return }
        credentials = ScreenshotFixtures.credentials
        library = ScreenshotFixtures.library
        exploreTracks = ScreenshotFixtures.exploreTracks
        exploreStreams = ScreenshotFixtures.exploreStreams
        switch scene {
        case .stage:
            broadcast.setScreenshotState(.idle, levelDb: -27)
        case .live:
            broadcast.setScreenshotState(.live(since: ScreenshotFixtures.liveSince), levelDb: -14)
        case .login, .signup, .library, .explore, .account, .edit, .editDemo:
            break
        }
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

    /// What the account sheet shows for the signed-in station. The deployed
    /// connect/refresh responses carry no `station` yet (see ConnectResponse),
    /// so gaps are filled from the station attached to the user's own library
    /// tracks, which the library endpoint has always included.
    struct AccountStation {
        var name: String?
        var slug: String?
        var imageURL: URL?
    }

    var accountStation: AccountStation {
        let session = credentials?.station
        let owned = library.first { $0.owner == true }?.station
        return AccountStation(
            name: session?.name ?? owned?.name,
            slug: session?.slug ?? owned?.slug,
            imageURL: (session?.image ?? owned?.image).flatMap(URL.init(string:))
        )
    }

    func login(email: String, password: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            try await connectDevice(email: email, password: password)
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Creates an account the way the website does (POST /auth/signup), then
    /// connects this device with the new credentials so the session ends up
    /// identical to a login's (stream key, device-scoped refresh token).
    /// Errors land in signUpError; success flips isLoggedIn.
    func signUp(email: String, stationName: String, password: String) async {
        isSigningUp = true
        signUpError = nil
        defer { isSigningUp = false }
        do {
            _ = try await api.signUp(email: email, stationName: stationName, password: password)
        } catch APIError.server(let status, _) where status == 409 {
            signUpError = "An account with this email already exists. Try logging in instead."
            return
        } catch APIError.server(let status, _) where status == 400 {
            // Joi validation or a failed account setup; the server's body is
            // plain text here, so use our own words.
            signUpError = "We couldn't create your account. Check your details and try again."
            return
        } catch {
            signUpError = error.localizedDescription
            return
        }
        do {
            try await connectDevice(email: email, password: password)
        } catch {
            // The account exists; only the device hand-off failed (network).
            signUpError = "Your account was created, but we couldn't sign you in. Please log in."
        }
    }

    /// POST /v1/devices/connect with this device's identity; persists the
    /// resulting session and makes it current.
    private func connectDevice(email: String, password: String) async throws {
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
        guard credentials != nil, !isLoadingExplore, !ScreenshotMode.isActive else { return }
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

    /// Saves an explore track into the library. Returns true on success so
    /// the UI can confirm with a haptic.
    func saveTrack(_ track: LibraryTrack) async -> Bool {
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return false }
        do {
            try await api.saveTrack(id: track.id, accessToken: token)
        } catch APIError.server(let status, _) where status == 409 {
            // Already saved — the desired state holds, so fall through.
        } catch {
            exploreError = error.localizedDescription
            return false
        }
        if let index = exploreTracks.firstIndex(where: { $0.id == track.id }) {
            exploreTracks[index].saved = true
        }
        await loadLibrary()
        return true
    }

    /// Removes a saved (another station's) track from the library. Returns
    /// true on success so the UI can confirm.
    func removeSavedTrack(_ track: LibraryTrack) async -> Bool {
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return false }
        do {
            try await api.unsaveTrack(id: track.id, accessToken: token)
        } catch APIError.server(let status, _) where status == 404 {
            // Wasn't saved (or already removed) — the desired state holds.
        } catch {
            libraryError = error.localizedDescription
            return false
        }
        // The row vanishes, so playback would outlive its UI otherwise.
        if player.playingKey == TrackPlayer.key(for: track) {
            player.stop()
        }
        library.removeAll { $0.id == track.id }
        if let index = exploreTracks.firstIndex(where: { $0.id == track.id }) {
            exploreTracks[index].saved = false
        }
        return true
    }

    func loadLibrary() async {
        guard credentials != nil, !isLoadingLibrary, !ScreenshotMode.isActive else { return }
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

    /// Returns true on success; on failure the error lands in libraryError.
    func updateTrack(_ track: LibraryTrack, title: String, description: String) async -> Bool {
        await ensureFreshSession()
        guard let token = credentials?.accessToken else { return false }
        do {
            try await api.updateTrack(id: track.id, title: title, description: description, accessToken: token)
            if let index = library.firstIndex(where: { $0.id == track.id }) {
                library[index].title = title
                library[index].description = description
            }
            return true
        } catch {
            libraryError = error.localizedDescription
            return false
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
}
