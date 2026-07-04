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
    let title: String?
    let location: String?
    let image: String?
    let duration: Int?
    let tags: [String]?
    let streamedAt: String?
    let createdAt: String?
    let listens: Int?
    let owner: Bool?
    let saved: Bool?
    let station: TrackStation?

    var audioURL: URL? {
        location.flatMap(URL.init(string:))
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

    /// Channels currently on air across the platform.
    func exploreStreams(accessToken: String) async throws -> [ExploreStream] {
        try await authorizedGet(path: "/v1/explore/streams", queryItems: [], accessToken: accessToken)
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
