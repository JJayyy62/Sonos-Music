import Foundation

/// Apple の公開検索API（iTunes Search API）による Apple Music カタログ検索
///
/// MusicKit のカタログ検索には開発者トークン（MusicKit を有効にした App ID での署名）が必要なため、
/// それが使えない環境でも検索・アルバムの曲一覧を出せるようにする。ここで得られる曲ID・アルバムIDは
/// Apple Music のカタログIDと同じなので、そのまま Sonos で再生できる。プレイリストは検索できない。
enum ITunesCatalog {
    private static var country: String {
        (Locale.current.region?.identifier ?? "JP").lowercased()
    }

    private static var language: String {
        Locale.current.language.languageCode?.identifier == "ja" ? "ja_jp" : "en_us"
    }

    static func search(_ term: String) async throws -> CatalogSearchResults {
        async let songs = request("search", ["term": term, "entity": "song", "limit": "25"])
        async let albums = request("search", ["term": term, "entity": "album", "limit": "20"])
        async let artists = request("search", ["term": term, "entity": "musicArtist", "limit": "10"])
        return CatalogSearchResults(
            tracks: try await songs.compactMap(\.track),
            albums: try await albums.compactMap(\.album),
            playlists: [],
            artists: try await artists.compactMap(\.artist))
    }

    static func albumTracks(_ albumID: String) async throws -> [CatalogTrack] {
        let results = try await request("lookup", ["id": albumID, "entity": "song", "limit": "200"])
        return results.compactMap(\.track)
    }

    static func artistAlbums(_ artistID: String) async throws -> [CatalogCollection] {
        let results = try await request("lookup", ["id": artistID, "entity": "album", "limit": "100"])
        return results.compactMap(\.album)
    }

    static func artistSongs(_ artistID: String) async -> [CatalogTrack] {
        let results = try? await request("lookup", ["id": artistID, "entity": "song", "limit": "15"])
        return results?.compactMap(\.track) ?? []
    }

    // MARK: - Request

    private struct Response: Decodable { let results: [Item] }

    private struct Item: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackId: Int?
        let trackName: String?
        let collectionId: Int?
        let collectionName: String?
        let artistId: Int?
        let artistName: String?
        let artworkUrl100: String?
        let trackTimeMillis: Int?
        let trackNumber: Int?
        let releaseDate: String?
        let primaryGenreName: String?

        /// 100x100 の画像URLを大きいサイズに差し替える
        var artwork: URL? {
            artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
        }

        var track: CatalogTrack? {
            guard wrapperType == "track", kind == "song", let trackId, let trackName else { return nil }
            return CatalogTrack(service: .appleMusic, serviceID: String(trackId), title: trackName,
                                artist: artistName ?? "", album: collectionName,
                                albumID: collectionId.map(String.init), artworkURL: artwork,
                                duration: trackTimeMillis.map { Double($0) / 1000 }, number: trackNumber)
        }

        var album: CatalogCollection? {
            guard wrapperType == "collection", let collectionId, let collectionName else { return nil }
            return CatalogCollection(service: .appleMusic, kind: .album, serviceID: String(collectionId),
                                     title: collectionName, subtitle: artistName ?? "", artworkURL: artwork,
                                     detail: [primaryGenreName, releaseDate.map { String($0.prefix(4)) }]
                                        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        }

        var artist: CatalogArtist? {
            guard wrapperType == "artist", let artistId, let artistName else { return nil }
            return CatalogArtist(service: .appleMusic, serviceID: String(artistId), name: artistName, artworkURL: nil)
        }
    }

    private static func request(_ path: String, _ query: [String: String]) async throws -> [Item] {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = (query.merging(["country": country, "lang": language, "media": "music"]) { a, _ in a })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}
