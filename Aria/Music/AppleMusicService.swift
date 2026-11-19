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

    @ObservationIgnored private var traitsCache: [String: [String]] = [:]
    @ObservationIgnored private var storefront: String?

    func requestAuthorization() async {
        status = await MusicAuthorization.request()
    }

    func search(_ term: String) async throws -> AppleMusicSearchResults {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Playlist.self, Artist.self])
        request.limit = 20
        let response = try await request.response()
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
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let attributes = ((json?["data"] as? [[String: Any]])?.first)?["attributes"] as? [String: Any]
            var traits = Set<String>()
            (attributes?["audioTraits"] as? [String])?.forEach { traits.insert($0) }
            (attributes?["audioVariants"] as? [String])?.forEach { traits.insert($0) }
            let result = Array(traits)
            traitsCache[key] = result
            return result
        } catch {
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
        guard isAuthorized else { return [] }
        var shelves: [AppleMusicShelf] = []

        if let recent = try? await MusicRecentlyPlayedContainerRequest().response() {
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
}
