import Foundation
import CryptoKit

// MARK: - מודלים

struct SpotifyImage: Decodable, Hashable { let url: String }
struct SpotifyArtist: Decodable, Hashable { let name: String }
struct SpotifyAlbum: Decodable, Hashable { let images: [SpotifyImage]? }
struct SpotifyOwner: Decodable, Hashable { let display_name: String? }

struct SpotifyTrack: Decodable, Identifiable, Hashable {
    let uri: String
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
    var id: String { uri }
    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var artURL: URL? { album?.images?.last.flatMap { URL(string: $0.url) } }
}

struct SpotifyPlaylist: Decodable, Identifiable, Hashable {
    let uri: String
    let name: String
    let images: [SpotifyImage]?
    let owner: SpotifyOwner?
    var id: String { uri }
    var artURL: URL? { images?.first.flatMap { URL(string: $0.url) } }
}

struct SpotifyDevice: Decodable, Identifiable, Hashable {
    let deviceID: String?
    let name: String
    let type: String
    let isActive: Bool
    var id: String { deviceID ?? name }

    enum CodingKeys: String, CodingKey {
        case deviceID = "id", name, type, isActive = "is_active"
    }
}

enum SpotifyError: LocalizedError {
    case notConfigured, notConnected, authFailed, http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "חסר Spotify Client ID (ראה README)"
        case .notConnected: "Spotify לא מחובר"
        case .authFailed: "ההתחברות ל-Spotify נכשלה"
        case .http(404): "הרמקול לא זמין כרגע ב-Spotify. נסה לרענן את רשימת הרמקולים."
        case .http(403): "Spotify סירב לבקשה (נדרש Premium, וייתכן שצריך להוסיף את המשתמש שלך ב-Dashboard)"
        case .http(let code): "שגיאת Spotify (\(code))"
        }
    }
}

// MARK: - שירות

/// חיבור ל-Spotify בשיטת OAuth + PKCE:
/// אין סיסמה ואין "סוד" בתוך האפליקציה. רק מפתח גישה זמני שנשמר ב-Keychain.
@MainActor
@Observable
final class SpotifyService {
    static let shared = SpotifyService()
    static let redirectURI = "songmilim://spotify-callback"
    static let callbackScheme = "songmilim"

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private(set) var isConnected = false
    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var pendingVerifier: String?
    @ObservationIgnored private var pendingState: String?

    private static let keychainKey = "spotify.tokens"
    private static let scopes = [
        "user-read-playback-state", "user-modify-playback-state",
        "user-read-currently-playing", "playlist-read-private", "user-library-read",
    ]

    var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientID.contains("$(") }

    init() {
        if let data = Keychain.load(Self.keychainKey),
           let saved = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = saved
            isConnected = true
        }
    }

    // MARK: התחברות

    func authorizationURL() throws -> URL {
        guard isConfigured else { throw SpotifyError.notConfigured }
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        return components.url!
    }

    func handleCallback(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // בדיקת state מונעת ממישהו "להשתיל" התחברות זרה
        guard let state = value("state"), state == pendingState,
              let code = value("code"), let verifier = pendingVerifier else {
            throw SpotifyError.authFailed
        }
        pendingVerifier = nil
        pendingState = nil
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    func disconnect() {
        tokens = nil
        Keychain.delete(Self.keychainKey)
        isConnected = false
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if form["grant_type"] == "refresh_token" { disconnect() }
            throw SpotifyError.authFailed
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        let newTokens = Tokens(
            access: result.access_token,
            refresh: result.refresh_token ?? tokens?.refresh ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(result.expires_in - 60))
        )
        tokens = newTokens
        Keychain.save(try JSONEncoder().encode(newTokens), for: Self.keychainKey)
        isConnected = true
    }

    private func accessToken() async throws -> String {
        guard let current = tokens else { throw SpotifyError.notConnected }
        if current.expiresAt < Date() {
            try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": current.refresh,
                "client_id": clientID,
            ])
        }
        guard let access = tokens?.access else { throw SpotifyError.notConnected }
        return access
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    // MARK: Web API

    @discardableResult
    private func api(_ method: String, _ path: String, query: [URLQueryItem] = [],
                     body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        let token = try await accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { disconnect() }
        guard (200..<300).contains(code) else { throw SpotifyError.http(code) }
        return data
    }

    func devices() async throws -> [SpotifyDevice] {
        struct Response: Decodable { let devices: [SpotifyDevice] }
        let data = try await api("GET", "/me/player/devices")
        return try JSONDecoder().decode(Response.self, from: data).devices.filter { $0.deviceID != nil }
    }

    func myPlaylists() async throws -> [SpotifyPlaylist] {
        struct Response: Decodable { let items: [SpotifyPlaylist?] }
        let data = try await api("GET", "/me/playlists", query: [URLQueryItem(name: "limit", value: "50")])
        return try JSONDecoder().decode(Response.self, from: data).items.compactMap { $0 }
    }

    func search(_ text: String) async throws -> (tracks: [SpotifyTrack], playlists: [SpotifyPlaylist]) {
        struct Page<T: Decodable>: Decodable { let items: [T?] }
        struct Response: Decodable {
            let tracks: Page<SpotifyTrack>?
            let playlists: Page<SpotifyPlaylist>?
        }
        let data = try await api("GET", "/search", query: [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "type", value: "track,playlist"),
            URLQueryItem(name: "limit", value: "15"),
        ])
        let result = try JSONDecoder().decode(Response.self, from: data)
        return (result.tracks?.items.compactMap { $0 } ?? [], result.playlists?.items.compactMap { $0 } ?? [])
    }

    /// מנגן שיר או פלייליסט על רמקול מסוים (כולל רמקולי Sonos דרך Spotify Connect)
    func play(trackURI: String? = nil, contextURI: String? = nil, on deviceID: String) async throws {
        // קודם מעבירים את הניגון לרמקול, ואז מתחילים לנגן
        try await api("PUT", "/me/player", body: ["device_ids": [deviceID], "play": false])
        var body: [String: Any] = [:]
        if let trackURI { body["uris"] = [trackURI] }
        if let contextURI { body["context_uri"] = contextURI }
        try await api("PUT", "/me/player/play", query: [URLQueryItem(name: "device_id", value: deviceID)], body: body)
    }
}

// MARK: - PKCE

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
