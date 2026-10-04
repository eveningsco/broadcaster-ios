import Foundation

struct Station: Codable, Equatable {
    let id: Int
    let slug: String
    let name: String
}

// channelId/station only exist once the updated API server is deployed; decode
// them as optional so the app works against the current production response.
struct ConnectResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let streamKey: String
    let expiresIn: Int
    let channelId: String?
    let station: Station?
}

struct RefreshResponse: Codable {
    let accessToken: String
    let streamKey: String
    let expiresIn: Int
    let channelId: String?
    let station: Station?
}

/// Website-style tokens from POST /auth/signup: not device-scoped (no stream
/// key), so the app follows a sign-up with /v1/devices/connect.
struct AuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct StreamStatus: Codable {
    let online: Bool
    let listeners: Int
}

struct LibraryTrack: Codable, Identifiable, Equatable {
    struct TrackStation: Codable, Equatable {
        let id: Int?
        let name: String?
        let slug: String?
        let image: String?
    }

    let id: Int
    var title: String?
    var description: String?
    let location: String?
    let image: String?
    let duration: Int?
    let tags: [String]?
    let streamedAt: String?
    let createdAt: String?
    let listens: Int?
    let owner: Bool?
    var saved: Bool?
    let station: TrackStation?

    var audioURL: URL? {
        location.flatMap(URL.init(string:))
    }

    /// The track's public page on the website; needs the station slug.
    var webURL: URL? {
        guard let slug = station?.slug else { return nil }
        return Config.webBaseURL.appendingPathComponent("\(slug)/tracks/\(id)")
    }

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (streamedAt ?? createdAt).flatMap(formatter.date(from:))
    }
}

/// A currently-live channel from GET /v1/explore/streams (media server stream
/// state merged with the channel's live info and station).
struct ExploreStream: Codable, Identifiable, Equatable {
    let channelId: String
    let type: String?
    let subscribers: Int?
    let name: String?
    let title: String?
    let host: String?
    let image: String?
    let station: LibraryTrack.TrackStation?

    var id: String { channelId }

    var displayName: String {
        name ?? title ?? station?.name ?? "Live stream"
    }

    var streamURL: URL {
        Config.mediaBaseURL.appendingPathComponent("/s/\(channelId)")
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

enum APIError: LocalizedError {
    case invalidCredentials
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password."
        case .server(let status, let message):
            return message ?? "Server error (\(status))."
        }
    }
}

struct EveningsAPI {
    var baseURL = Config.apiBaseURL
    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    func connect(email: String, password: String, deviceId: String, deviceName: String) async throws -> ConnectResponse {
        try await post(
            path: "/v1/devices/connect",
            body: ["email": email, "password": password, "deviceId": deviceId, "deviceName": deviceName]
        )
    }

    /// Creates a station + account — the same endpoint and body as the
    /// website's sign-up form, so the account gets the same setup (channel,
    /// stream key, trial subscription). 409 when the email is taken; 400
    /// when the server rejects a field (Joi) or account setup fails.
    func signUp(email: String, stationName: String, password: String) async throws -> AuthTokens {
        try await post(
            path: "/auth/signup",
            body: ["email": email, "stationName": stationName, "password": password]
        )
    }

    func refresh(refreshToken: String) async throws -> RefreshResponse {
        try await post(path: "/v1/devices/refresh", body: ["refreshToken": refreshToken])
    }

    /// Public (rate-limited) endpoint; no auth required.
    func status(channelId: String) async throws -> StreamStatus {
        let url = baseURL.appendingPathComponent("/v1/streams/\(channelId)/status")
        let (data, response) = try await session.data(from: url)
        try check(response: response, data: data)
        return try decoder.decode(StreamStatus.self, from: data)
    }

    /// Updates a track's editable metadata. The server rejects an empty
    /// title, so callers should validate before sending.
    func updateTrack(id: Int, title: String, description: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/tracks/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["title": title, "description": description])
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    /// Soft-deletes a track the station owns (restorable server-side).
    func deleteTrack(id: Int, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/tracks/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    /// The station's own tracks plus saved tracks, newest first.
    func library(accessToken: String, page: Int = 0) async throws -> [LibraryTrack] {
        try await authorizedGet(
            path: "/v1/library",
            queryItems: [URLQueryItem(name: "page", value: String(page))],
            accessToken: accessToken
        )
    }

    /// Published tracks from all stations, newest first.
    func exploreTracks(accessToken: String, page: Int = 0) async throws -> [LibraryTrack] {
        try await authorizedGet(
            path: "/v1/explore/tracks",
            queryItems: [URLQueryItem(name: "page", value: String(page))],
            accessToken: accessToken
        )
    }

    /// Saves a published track from another station into the library.
    /// The server answers 409 if it's already saved.
    func saveTrack(id: Int, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/explore/tracks/\(id)/save"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    /// Removes a previously saved track from the library (the inverse of
    /// saveTrack). The server answers 404 if it wasn't saved.
    func unsaveTrack(id: Int, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/explore/tracks/\(id)/save"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    /// Channels currently on air across the platform.
    func exploreStreams(accessToken: String) async throws -> [ExploreStream] {
        try await authorizedGet(path: "/v1/explore/streams", queryItems: [], accessToken: accessToken)
    }

    struct UploadedTrack: Codable {
        let id: Int
    }

    /// Multipart upload to the library. The multipart body is assembled in a
    /// temp file and streamed, so hour-long recordings never sit in memory.
    func uploadTrack(
        fileURL: URL,
        filename: String? = nil,
        accessToken: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> UploadedTrack {
        let boundary = "evenings-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/tracks"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = try assembleMultipartBody(
            fileURL: fileURL,
            filename: filename ?? fileURL.lastPathComponent,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
        try check(response: response, data: data)
        return try decoder.decode(UploadedTrack.self, from: data)
    }

    func updateTrackTitle(id: Int, title: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/tracks/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["title": title])
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    private func assembleMultipartBody(fileURL: URL, filename: String, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).tmp")

        var prefix = "--\(boundary)\r\n"
        prefix += "Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n"
        prefix += "Content-Type: audio/mp4\r\n\r\n"
        let suffix = "\r\n--\(boundary)--\r\n"

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: bodyURL)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data(prefix.utf8))

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }

        try writer.write(contentsOf: Data(suffix.utf8))
        return bodyURL
    }

    private func authorizedGet<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        accessToken: String
    ) async throws -> T {
        var url = baseURL.appendingPathComponent(path)
        if !queryItems.isEmpty {
            url = url.appending(queryItems: queryItems)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        if http.statusCode == 401 {
            throw APIError.invalidCredentials
        }
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
        throw APIError.server(status: http.statusCode, message: message)
    }
}
