import Foundation
import MusicKit
import Observation

struct AppleMusicSearchResults {
    var songs: [Song] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var artists: [Artist] = []

    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty }
}

enum AppleMusicItem: Identifiable, Hashable {
    case album(Album)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .album(let album): return "album-\(album.id.rawValue)"
        case .playlist(let playlist): return "playlist-\(playlist.id.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .album(let album): return album.title
        case .playlist(let playlist): return playlist.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let album): return album.artistName
        case .playlist(let playlist): return playlist.curatorName ?? "Apple Music"
        }
    }

    func artworkURL(_ size: Int) -> URL? {
        switch self {
        case .album(let album): return album.artwork?.url(width: size, height: size)
        case .playlist(let playlist): return playlist.artwork?.url(width: size, height: size)
        }
    }

    /// Sonos から再生できるカタログアイテムか
    var isPlayableOnSonos: Bool {
        switch self {
        case .album(let album): return AppleMusicSonos.isCatalogAlbumID(album.id.rawValue)
        case .playlist(let playlist): return AppleMusicSonos.isCatalogPlaylistID(playlist.id.rawValue)
        }
    }
}

struct AppleMusicShelf: Identifiable {
    let id = UUID()
    let title: String
    let items: [AppleMusicItem]
}

@Observable @MainActor
final class AppleMusicService {
    static let shared = AppleMusicService()

    private(set) var status: MusicAuthorization.Status = MusicAuthorization.currentStatus
    var isAuthorized: Bool { status == .authorized }

    /// Apple Music API（開発者トークンが必要）が使えるか。nil はまだ試していない
    private(set) var apiAvailable: Bool?
    /// Apple Music API が使えない理由（設定画面・ホームに表示する）
    private(set) var apiProblem: String?
    /// ライブラリ（自分のプレイリスト・アルバム）を読めなかった理由
    private(set) var libraryProblem: String?

    /// MusicKit のカタログ検索が使えないときは公開検索APIに切り替える
    var usesFallbackSearch: Bool { !isAuthorized || apiAvailable == false }

    @ObservationIgnored private var traitsCache: [String: [String]] = [:]
    @ObservationIgnored private var storefront: String?

    func requestAuthorization() async {
        status = await MusicAuthorization.request()
    }

    /// 開発者トークンの取得に失敗したことを記録する
    private func noteAPIFailure(_ error: Error) {
        let text = String(describing: error)
        if text.contains("developerToken") || text.contains("DeveloperToken") {
            apiAvailable = false
            apiProblem = "おすすめ・ライブラリの同期・音質情報には Apple Music API が必要です。Apple Music API は、有料の Apple Developer Program のアカウントで署名し、MusicKit を有効にしたアプリでのみ使えます。"
        } else if text.contains("userToken") || text.contains("UserToken") || text.contains("privacyAcknowledgement") {
            apiAvailable = true
            libraryProblem = "Apple Musicのアカウントにアクセスできません。このiPhoneでApple Musicにサインインし、ミュージックアプリで「ライブラリを同期」をオンにしてください（シミュレータではサインインできません）。"
        }
    }

    func search(_ term: String) async throws -> AppleMusicSearchResults {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Playlist.self, Artist.self])
        request.limit = 20
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
            apiAvailable = true
        } catch {
            noteAPIFailure(error)
            throw error
        }
        return AppleMusicSearchResults(
            songs: Array(response.songs),
            albums: Array(response.albums),
            playlists: Array(response.playlists),
            artists: Array(response.artists))
    }

    enum CatalogType: String { case songs, albums }

    /// Apple Music API の audioTraits / audioVariants（"lossless", "atmos" など）
    func audioTraits(type: CatalogType, id: String) async -> [String] {
        let key = "\(type.rawValue)/\(id)"
        if let cached = traitsCache[key] { return cached }
        guard isAuthorized else { return [] }
        do {
            let storefront = try await currentStorefront()
            guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/\(type.rawValue)/\(id)?extend=audioVariants") else { return [] }
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            apiAvailable = true
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let attributes = ((json?["data"] as? [[String: Any]])?.first)?["attributes"] as? [String: Any]
            var traits = Set<String>()
            (attributes?["audioTraits"] as? [String])?.forEach { traits.insert($0) }
            (attributes?["audioVariants"] as? [String])?.forEach { traits.insert($0) }
            let result = Array(traits)
            traitsCache[key] = result
            return result
        } catch {
            noteAPIFailure(error)
            return []
        }
    }

    private func currentStorefront() async throws -> String {
        if let storefront { return storefront }
        let code = try await MusicDataRequest.currentCountryCode
        storefront = code
        return code
    }

    /// ホーム画面の棚（最近再生した項目＋おすすめ）
    func homeShelves() async -> [AppleMusicShelf] {
        guard isAuthorized, apiAvailable != false else { return [] }
        var shelves: [AppleMusicShelf] = []

        let recent: MusicRecentlyPlayedContainerResponse?
        do {
            recent = try await MusicRecentlyPlayedContainerRequest().response()
            apiAvailable = true
        } catch {
            noteAPIFailure(error)
            recent = nil
        }
        if apiAvailable == false { return [] }
        if let recent {
            let items = recent.items.compactMap { (item) -> AppleMusicItem? in
                switch item {
                case .album(let album): return .album(album)
                case .playlist(let playlist): return .playlist(playlist)
                default: return nil
                }
            }.filter(\.isPlayableOnSonos)
            if !items.isEmpty { shelves.append(AppleMusicShelf(title: "最近再生した項目", items: items)) }
        }

        if let response = try? await MusicPersonalRecommendationsRequest().response() {
            for recommendation in response.recommendations {
                let items = (recommendation.albums.map { AppleMusicItem.album($0) }
                             + recommendation.playlists.map { AppleMusicItem.playlist($0) })
                    .filter(\.isPlayableOnSonos)
                if !items.isEmpty {
                    shelves.append(AppleMusicShelf(title: recommendation.title ?? "おすすめ", items: items))
                }
            }
        }
        return shelves
    }

    // MARK: - Library（自分のプレイリスト・アルバム）

    /// ライブラリのプレイリスト（ID が p. で始まり、Sonos で再生できる）
    func libraryPlaylists() async -> [CatalogCollection] {
        guard isAuthorized, apiAvailable != false else { return [] }
        guard let json = await libraryJSON("me/library/playlists?limit=100") else { return [] }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String else { return nil }
            return CatalogCollection(service: .appleMusic, kind: .playlist, serviceID: id, title: name,
                                     subtitle: "ライブラリ", artworkURL: Self.artworkURL(attributes["artwork"]))
        }
    }

    /// ライブラリのアルバム。Sonos はライブラリID（l.）を再生できないので、対応するカタログIDに置き換える
    func libraryAlbums() async -> [CatalogCollection] {
        guard isAuthorized, apiAvailable != false else { return [] }
        guard let json = await libraryJSON("me/library/albums?limit=100&include=catalog") else { return [] }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String,
                  let catalog = ((item["relationships"] as? [String: Any])?["catalog"] as? [String: Any])?["data"] as? [[String: Any]],
                  let catalogID = catalog.first?["id"] as? String else { return nil }
            return CatalogCollection(service: .appleMusic, kind: .album, serviceID: catalogID, title: name,
                                     subtitle: attributes["artistName"] as? String ?? "",
                                     artworkURL: Self.artworkURL(attributes["artwork"]))
        }
    }

    /// ライブラリのプレイリストの曲（カタログIDのある曲だけ）
    func libraryPlaylistTracks(_ id: String) async throws -> [CatalogTrack] {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(id)/tracks?limit=100") else { return [] }
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String else { return nil }
            let catalogID = (attributes["playParams"] as? [String: Any])?["catalogId"] as? String
            return CatalogTrack(service: .appleMusic, serviceID: catalogID ?? "", title: name,
                                artist: attributes["artistName"] as? String ?? "",
                                album: attributes["albumName"] as? String, albumID: nil,
                                artworkURL: Self.artworkURL(attributes["artwork"]),
                                duration: (attributes["durationInMillis"] as? Double).map { $0 / 1000 },
                                number: nil)
        }
    }

    private func libraryJSON(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.music.apple.com/v1/\(path)") else { return nil }
        do {
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            apiAvailable = true
            libraryProblem = nil
            return try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        } catch {
            noteAPIFailure(error)
            if libraryProblem == nil, apiAvailable != false {
                libraryProblem = "Apple Musicのライブラリを読み込めませんでした（\(error.localizedDescription)）"
            }
            return nil
        }
    }

    /// Apple Music API の artwork（url に {w}x{h} が入っている）
    private static func artworkURL(_ value: Any?) -> URL? {
        guard let artwork = value as? [String: Any], let template = artwork["url"] as? String else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: "400").replacingOccurrences(of: "{h}", with: "400"))
    }
}
