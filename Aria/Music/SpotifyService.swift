import CryptoKit
import Foundation
import Observation
import Security

/// Spotify Web API（カタログの検索・ホームの棚・アルバムの曲一覧）
///
/// 再生そのものは Sonos に登録済みの Spotify アカウントで行う。ここで使うのは「何を再生するか」を探すためだけ。
/// Spotify の API を使うには、利用者が developer.spotify.com でアプリを作り、その Client ID を設定画面に入れる。
@Observable @MainActor
final class SpotifyService {
    static let shared = SpotifyService()

    static let redirectURI = "aria-sonos://spotify-callback"
    static let callbackScheme = "aria-sonos"
    private static let scopes = "user-read-recently-played user-library-read playlist-read-private playlist-read-collaborative user-top-read"
    private static let clientIDKey = "spotifyClientID"

    enum SpotifyError: LocalizedError {
        case noClientID, notConnected, authFailed(String), http(Int)

        var errorDescription: String? {
            switch self {
            case .noClientID: return "SpotifyのClient IDが設定されていません"
            case .notConnected: return "Spotifyにログインしていません"
            case .authFailed(let reason): return "Spotifyのログインに失敗しました（\(reason)）"
            case .http(let code): return "Spotifyからエラーが返されました（\(code)）"
            }
        }
    }

    var clientID: String = UserDefaults.standard.string(forKey: SpotifyService.clientIDKey) ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: Self.clientIDKey) }
    }

    private(set) var isConnected = Keychain.read("spotify.refresh") != nil
    private(set) var userName: String?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast
    @ObservationIgnored private var pendingVerifier: String?

    // MARK: - Login (Authorization Code + PKCE)

    /// ログイン画面のURL。表示は WebAuthenticationSession に任せる
    func authorizationURL() throws -> URL {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw SpotifyError.noClientID }
        let verifier = Self.randomVerifier()
        pendingVerifier = verifier
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes),
        ]
        return components.url!
    }

    func completeLogin(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw SpotifyError.authFailed(error) }
        guard let code = items.first(where: { $0.name == "code" })?.value, let verifier = pendingVerifier else {
            throw SpotifyError.authFailed("コードがありません")
        }
        pendingVerifier = nil
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        isConnected = true
        await loadProfile()
    }

    func logout() {
        Keychain.delete("spotify.refresh")
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
        userName = nil
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let reason = (try? JSONDecoder().decode(TokenError.self, from: data))?.error_description ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw SpotifyError.authFailed(reason)
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in - 60))
        if let refresh = token.refresh_token { Keychain.save(refresh, for: "spotify.refresh") }
    }

    private func validToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = Keychain.read("spotify.refresh") else { throw SpotifyError.notConnected }
        guard !clientID.isEmpty else { throw SpotifyError.noClientID }
        do {
            try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        } catch {
            logout()
            throw error
        }
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    func loadProfile() async {
        struct Me: Decodable { let display_name: String?; let id: String }
        if let me: Me = try? await get("me") { userName = me.display_name ?? me.id }
    }

    // MARK: - API

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SpotifyError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ term: String) async throws -> CatalogSearchResults {
        struct Response: Decodable {
            let tracks: Page<SPTrack>?
            let albums: Page<SPAlbum>?
            let playlists: Page<SPPlaylist>?
            let artists: Page<SPArtist>?
        }
        let response: Response = try await get("search", [
            "q": term, "type": "track,album,playlist,artist", "limit": "20", "market": "from_token",
        ])
        return CatalogSearchResults(
            tracks: response.tracks?.values.map { $0.catalog() } ?? [],
            albums: response.albums?.values.map(\.catalog) ?? [],
            playlists: response.playlists?.values.map(\.catalog) ?? [],
            artists: response.artists?.values.map(\.catalog) ?? [])
    }

    /// ホームの棚（最近再生した曲のアルバム、保存したアルバム、自分のプレイリスト）
    func homeShelves() async -> [CatalogShelf] {
        guard isConnected else { return [] }
        if userName == nil { await loadProfile() }
        var shelves: [CatalogShelf] = []

        struct Played: Decodable { let track: SPTrack? }
        if let recent: Page<Played> = try? await get("me/player/recently-played", ["limit": "50"]) {
            var seen = Set<String>()
            let albums = recent.values.compactMap(\.track?.album).filter { seen.insert($0.id).inserted }.map(\.catalog)
            if !albums.isEmpty { shelves.append(CatalogShelf(service: .spotify, title: "最近再生した項目", items: albums)) }
        }
        struct Saved: Decodable { let album: SPAlbum? }
        if let saved: Page<Saved> = try? await get("me/albums", ["limit": "30"]) {
            let albums = saved.values.compactMap(\.album).map(\.catalog)
            if !albums.isEmpty { shelves.append(CatalogShelf(service: .spotify, title: "保存したアルバム", items: albums)) }
        }
        if let playlists: Page<SPPlaylist> = try? await get("me/playlists", ["limit": "30"]) {
            let items = playlists.values.map(\.catalog)
            if !items.isEmpty { shelves.append(CatalogShelf(service: .spotify, title: "プレイリスト", items: items)) }
        }
        return shelves
    }

    func tracks(of collection: CatalogCollection) async throws -> [CatalogTrack] {
        switch collection.kind {
        case .album:
            let album: SPAlbum = try await get("albums/\(collection.serviceID)", ["market": "from_token"])
            return album.tracks?.values.map { $0.catalog(album: album) } ?? []
        case .playlist:
            struct Item: Decodable { let track: SPTrack?; let item: SPTrack? }
            let page: Page<Item> = try await get("playlists/\(collection.serviceID)/tracks", ["limit": "100", "market": "from_token"])
            return page.values.compactMap { ($0.track ?? $0.item)?.catalog() }
        case .track:
            return []
        }
    }

    func artistAlbums(_ artist: CatalogArtist) async throws -> [CatalogCollection] {
        let page: Page<SPAlbum> = try await get("artists/\(artist.serviceID)/albums",
                                                ["include_groups": "album,single", "limit": "50", "market": "from_token"])
        return page.values.map(\.catalog)
    }

    func artistTopTracks(_ artist: CatalogArtist) async -> [CatalogTrack] {
        struct Response: Decodable { let tracks: [SPTrack] }
        let response: Response? = try? await get("artists/\(artist.serviceID)/top-tracks", ["market": "from_token"])
        return response?.tracks.map { $0.catalog() } ?? []
    }

    // MARK: - Helpers

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private struct TokenError: Decodable { let error_description: String? }
}

// MARK: - Spotify JSON

/// 一覧の中に null や壊れた要素が混ざっていても、読める要素だけ取り出す
private struct Page<T: Decodable>: Decodable {
    let values: [T]

    private struct Lossy: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = (try container.decodeIfPresent([Lossy].self, forKey: .items) ?? []).compactMap(\.value)
    }
}

private struct SPImage: Decodable { let url: String; let width: Int? }

private extension Array where Element == SPImage {
    /// 300px 前後の画像を選ぶ
    var bestURL: URL? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let pick = sorted.first { ($0.width ?? 0) >= 300 } ?? sorted.last
        return pick.flatMap { URL(string: $0.url) }
    }
}

private struct SPArtist: Decodable {
    let id: String
    let name: String
    let images: [SPImage]?

    var catalog: CatalogArtist {
        CatalogArtist(service: .spotify, serviceID: id, name: name, artworkURL: images?.bestURL)
    }
}

private struct SPAlbum: Decodable {
    let id: String
    let name: String
    let artists: [SPArtist]?
    let images: [SPImage]?
    let release_date: String?
    let album_type: String?
    let tracks: Page<SPTrack>?

    var artistName: String { artists?.map(\.name).joined(separator: ", ") ?? "" }

    var catalog: CatalogCollection {
        CatalogCollection(service: .spotify, kind: .album, serviceID: id, title: name, subtitle: artistName,
                          artworkURL: images?.bestURL,
                          detail: [album_type == "single" ? "シングル" : nil, release_date.map { String($0.prefix(4)) }]
                            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
    }
}

private struct SPTrack: Decodable {
    let id: String?
    let name: String
    let artists: [SPArtist]?
    let album: SPAlbum?
    let duration_ms: Int?
    let track_number: Int?

    func catalog(album container: SPAlbum? = nil) -> CatalogTrack {
        let album = self.album ?? container
        return CatalogTrack(service: .spotify, serviceID: id ?? "", title: name,
                            artist: artists?.map(\.name).joined(separator: ", ") ?? "",
                            album: album?.name, albumID: nil, artworkURL: album?.images?.bestURL,
                            duration: duration_ms.map { Double($0) / 1000 }, number: track_number)
    }
}

private struct SPPlaylist: Decodable {
    struct Owner: Decodable { let display_name: String? }
    let id: String
    let name: String
    let owner: Owner?
    let images: [SPImage]?

    var catalog: CatalogCollection {
        CatalogCollection(service: .spotify, kind: .playlist, serviceID: id, title: name,
                          subtitle: owner?.display_name ?? "Spotify", artworkURL: images?.bestURL)
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "Aria"

    static func save(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
