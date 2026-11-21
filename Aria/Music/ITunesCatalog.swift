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
        let songItems = try await songs
        let albumItems = try await albums
        let artistItems = try await artists

        var result = CatalogSearchResults(
            tracks: songItems.compactMap(\.track),
            albums: albumItems.compactMap(\.album),
            playlists: [],
            artists: artistItems.compactMap(\.artist))

        // この検索は Explicit（E マーク）の曲・アルバムを返さない。アーティストのアルバム一覧と曲目には含まれるので、
        // 検索に出てきた上位のアーティストについて、検索語に合う Explicit の曲・アルバムを足す
        let explicit = await explicitMatches(term: term,
                                             artistIDs: topArtistIDs(term: term, songs: songItems,
                                                                     others: artistItems + albumItems))
        let knownTracks = Set(result.tracks.map(\.serviceID))
        let knownAlbums = Set(result.albums.map(\.serviceID))
        result.tracks = explicit.tracks.filter { !knownTracks.contains($0.serviceID) } + result.tracks
        result.albums = explicit.albums.filter { !knownAlbums.contains($0.serviceID) } + result.albums
        return result
    }

    /// Explicit の曲を探すアーティスト（最大 3 人）。
    /// 曲名が検索語に合う曲のアーティストを優先し（例: "STAY" の The Kid LAROI）、残りは検索結果に多く出てくる順
    private static func topArtistIDs(term: String, songs: [Item], others: [Item]) -> [Int] {
        let words = normalizedWords(term)
        var ordered: [Int] = []
        func add(_ id: Int?) { if let id, !ordered.contains(id) { ordered.append(id) } }
        for song in songs where words.contains(where: { normalize(song.trackName ?? "").contains($0) }) {
            add(song.artistId)
        }
        var counts: [Int: Int] = [:]
        for id in (songs + others).compactMap(\.artistId) { counts[id, default: 0] += 1 }
        for id in counts.keys.sorted(by: { counts[$0, default: 0] > counts[$1, default: 0] }) { add(id) }
        return Array(ordered.prefix(3))
    }

    /// アーティストのアルバム（Explicit を含む）と、その曲目から、検索語に合う Explicit のものを探す
    private static func explicitMatches(term: String, artistIDs: [Int]) async -> (tracks: [CatalogTrack], albums: [CatalogCollection]) {
        guard !artistIDs.isEmpty else { return ([], []) }
        let words = normalizedWords(term)
        guard !words.isEmpty else { return ([], []) }
        // 日本のストアはアーティスト名がカタカナになる（ジャスティン・ビーバー）ので、英語表記も照合に使う。
        // アーティスト ID はどのストアでも同じなので、米国のストアで英語名を引く
        var englishName: [Int: String] = [:]
        for artist in (try? await request("lookup", ["id": artistIDs.map(String.init).joined(separator: ","),
                                                     "country": "us"])) ?? [] {
            if let id = artist.artistId, let name = artist.artistName { englishName[id] = name }
        }
        let allEnglishNames = englishName.values.joined(separator: " ")
        func matches(_ item: Item, name: String?) -> Bool {
            let nameOnly = normalize(name ?? "")
            let ownArtist = normalize((item.artistName ?? "") + " " + (item.artistId.flatMap { englishName[$0] } ?? ""))
            // 曲名（アルバム名）に検索語が入っている：残りの語は、このアーティストか、選んだアーティストの英語名にあればよい
            //   例: "STAY Justin Bieber" → 曲名 STAY、Justin Bieber は英語名で照合
            if words.contains(where: { nameOnly.contains($0) }) {
                let haystack = nameOnly + " " + ownArtist + " " + normalize(allEnglishNames)
                return words.allSatisfy { haystack.contains($0) }
            }
            // アーティスト名だけで検索したとき（例: "Peterparker69"）は、そのアーティスト自身の曲だけを出す
            return words.allSatisfy { ownArtist.contains($0) }
        }

        guard let albums = try? await request("lookup", ["id": artistIDs.map(String.init).joined(separator: ","),
                                                          "entity": "album", "limit": "200"]) else { return ([], []) }
        let albumItems = albums.filter { $0.wrapperType == "collection" }
        let explicitAlbums = albumItems.filter { $0.collectionExplicitness == "explicit" }
        let matchedAlbums = explicitAlbums.filter { matches($0, name: $0.collectionName) }.compactMap(\.album)

        // 曲目は Explicit のアルバムだけ見ればよい（それ以外の曲は通常の検索に出る）
        let ids = explicitAlbums.compactMap(\.collectionId).prefix(40).map(String.init).joined(separator: ",")
        guard !ids.isEmpty else { return ([], matchedAlbums) }
        guard let tracks = try? await request("lookup", ["id": ids, "entity": "song", "limit": "200"])
        else { return ([], matchedAlbums) }
        var seen = Set<String>()
        let matchedTracks = tracks
            .filter { $0.trackExplicitness == "explicit" && matches($0, name: $0.trackName) }
            .compactMap(\.track)
            .filter { seen.insert($0.title.lowercased()).inserted }
        return (Array(matchedTracks.prefix(10)), Array(matchedAlbums.prefix(10)))
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined()
    }

    private static func normalizedWords(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { !$0.isEmpty }
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
        let trackExplicitness: String?
        let collectionExplicitness: String?
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
                                duration: trackTimeMillis.map { Double($0) / 1000 }, number: trackNumber,
                                explicit: trackExplicitness == "explicit")
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
