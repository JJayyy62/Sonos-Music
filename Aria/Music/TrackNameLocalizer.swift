import Foundation

/// 曲名・アーティスト名・アルバム名の表示用（日本語など、端末の言語での表記）
struct TrackNames: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
}

/// 再生中の曲を Apple のカタログ（iTunes Search API）で引いて、表示を良くするための情報を得る。
///
/// - 曲名の表記：Sonos が英語表記（ローマ字）で返す日本の曲名を、端末の言語の表記にする
///   （例: "Arukuaround / sakanaction" → 「アルクアラウンド / サカナクション」）
/// - アートワーク：Sonos が渡す 400×400 の画像の代わりに、1200×1200 の画像を使う
///
/// 照合のしかた
/// - カタログの曲IDが分かる曲は ID で引く
/// - 分からない曲（ライブラリの曲、Spotify など）は「曲名 アーティスト名」で検索し、長さが ±3 秒以内のものだけ採用する
actor TrackNameLocalizer {
    static let shared = TrackNameLocalizer()

    /// カタログで見つかった曲
    struct CatalogMatch: Sendable {
        var title: String
        var artist: String
        var album: String?
        var artworkURL: URL?
    }

    /// 調べた結果（nil は「見つからなかった」）。回数制限や通信エラーで調べられなかった曲は入れない
    private var cache: [String: CatalogMatch?] = [:]

    /// アルバムごとの曲目（米国のストアの表記と、端末の地域のストアの表記）。
    /// 同じアルバムのほかの曲は、問い合わせずにここから引く（キューにアルバムが並ぶと、1 曲ずつ問い合わせて
    /// iTunes Search API の回数制限〈1 分あたり約 20 回〉にすぐ達し、ローマ字のまま残ってしまうため）
    private struct AlbumTracks {
        var us: [Song]
        var local: [Song]
    }
    private var albumCache: [String: AlbumTracks] = [:]

    private static func albumKey(artist: String, album: String?) -> String? {
        guard let album, !normalized(album).isEmpty else { return nil }
        return normalized(primaryArtist(artist)) + "|" + normalized(album)
    }
    private var inflight: [String: Task<Outcome, Never>] = [:]

    private enum Outcome {
        case found(CatalogMatch)
        case notFound
        case retryLater
    }
    /// iTunes Search API は 1 分あたり 20 回程度までなので、それを超えないように間隔をあける
    private var recentRequests: [Date] = []
    private let maxRequestsPerMinute = 18

    /// 端末の言語が日本語のときは日本語の表記で引く
    private static var prefersJapanese: Bool {
        Locale.current.language.languageCode?.identifier == "ja"
    }

    private static var country: String {
        (Locale.current.region?.identifier ?? "JP").lowercased()
    }

    /// 曲名を日本語表記にする必要があるか（端末の言語が日本語で、元の表記がすべて英数字のとき）
    static func needsLookup(title: String, artist: String) -> Bool {
        guard prefersJapanese, !title.isEmpty else { return false }
        return (title + artist).unicodeScalars.allSatisfy(\.isASCII)
    }

    /// 端末の言語での曲名・アーティスト名。元の表記と同じなら nil
    func names(title: String, artist: String, album: String?, duration: Double,
               catalogSongID: String?) async -> TrackNames? {
        guard Self.needsLookup(title: title, artist: artist),
              let match = await match(title: title, artist: artist, album: album, duration: duration,
                                      catalogSongID: catalogSongID),
              match.title != title || match.artist != artist else { return nil }
        return TrackNames(title: match.title, artist: match.artist, album: match.album ?? album)
    }

    private static func cacheKey(title: String, artist: String, album: String?, duration: Double,
                                 catalogSongID: String?) -> String {
        catalogSongID.map { "id:\($0)" } ?? "q:\(title)|\(artist)|\(album ?? "")|\(Int(duration))".lowercased()
    }

    /// まだ結果が出ていない（回数制限や通信エラーで調べられなかった）か。true なら、時間をおいてもう一度調べるとよい
    func isPending(title: String, artist: String, album: String?, duration: Double, catalogSongID: String?) -> Bool {
        guard !title.isEmpty else { return false }
        return cache[Self.cacheKey(title: title, artist: artist, album: album, duration: duration,
                                   catalogSongID: catalogSongID)] == nil
    }

    /// カタログで曲を探す（結果は曲ごとに覚えておく）
    func match(title: String, artist: String, album: String?, duration: Double,
               catalogSongID: String?) async -> CatalogMatch? {
        guard !title.isEmpty else { return nil }
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration,
                                catalogSongID: catalogSongID)
        if let cached = cache[key] { return cached }
        if let running = inflight[key] {
            if case .found(let match) = await running.value { return match }
            return nil
        }

        let task = Task<Outcome, Never> { [weak self] in
            guard let self else { return .retryLater }
            return await self.lookup(title: title, artist: artist, album: album, duration: duration,
                                     catalogSongID: catalogSongID)
        }
        inflight[key] = task
        let outcome = await task.value
        inflight[key] = nil
        switch outcome {
        case .found(let match):
            cache[key] = match
            return match
        case .notFound:
            cache[key] = .some(nil)
            return nil
        case .retryLater:
            return nil
        }
    }

    /// 曲を特定するしかた
    ///
    /// - カタログの曲 ID が分かる曲：その ID で引く
    /// - 分からない曲（ライブラリの曲など）：Sonos が返す英語表記（ローマ字）の曲名・アーティスト名で
    ///   **米国のストア**を検索する。米国のストアの表記は Sonos と同じなので、曲名が一致するものだけを採用できる。
    ///   （以前は長さだけで照合していたため、同じアーティストの長さが近い別の曲〈pink flamingo → Fallpoi〉を
    ///    取り違えることがあった）
    /// - 見つけた曲 ID を、端末の言語のストアで引き直して表示用の名前とアートワークを得る
    private func lookup(title: String, artist: String, album: String?, duration: Double,
                        catalogSongID: String?) async -> Outcome {
        var songID = catalogSongID
        /// 米国のストアで見つけた曲（端末の地域のストアにその ID がないときに使う）
        var usSong: Song?
        // 同じアルバムの曲目をすでに取ってあれば、問い合わせずにそこから探す
        if songID == nil, let key = Self.albumKey(artist: artist, album: album), let tracks = albumCache[key],
           let song = Self.track(in: tracks, title: title, duration: duration) {
            return Self.outcome(song)
        }
        if songID == nil {
            guard takeRequestSlot() else { return .retryLater }
            let query = ["term": "\(title) \(Self.primaryArtist(artist))", "entity": "song", "limit": "15",
                         "country": "us", "media": "music"]
            guard let results = await request("search", query) else { return .retryLater }
            // 同じ曲がシングルとアルバムの両方に入っていることがある（例：Hey phone は「Hey phone - Single」と
            // 「yo,」）。版によってアートワークが違うので、Sonos が示すアルバムと同じ版を選ぶ
            let sameAlbum = Self.bestMatch(in: results, title: title, artist: artist, duration: duration, album: album)
            let anyAlbum = sameAlbum ?? Self.bestMatch(in: results, title: title, artist: artist, duration: duration)
            var chosen = sameAlbum
            if chosen == nil {
                // 同じアルバムの版が検索に出ない：Explicit の版（Apple の検索は Explicit の曲を返さない）か、
                // 検索の上位に入らなかった版。アーティストのアルバム一覧と曲目から探す
                switch await explicitFallback(results: results, title: title, artist: artist, album: album,
                                              duration: duration) {
                case .found(let song, let isSameAlbum):
                    // アルバムが一致しなかったときは、検索で見つかった版を優先する
                    chosen = (isSameAlbum || anyAlbum == nil) ? song : anyAlbum
                case .notFound:
                    chosen = anyAlbum
                case .retryLater:
                    guard let anyAlbum else { return .retryLater }
                    chosen = anyAlbum
                }
            }
            guard let chosen else { return .notFound }
            songID = chosen.trackId.map(String.init)
            usSong = chosen
            guard songID != nil else { return .notFound }
            // 曲 ID の代わりにアルバムの曲目をまとめて引く（問い合わせ 1 回で、同じアルバムのほかの曲の分もそろう）
            if let collectionID = chosen.collectionId, Self.sameAlbum(chosen, album),
               let key = Self.albumKey(artist: artist, album: album) {
                guard takeRequestSlot() else { return .retryLater }
                if let local = await localTracks(albumID: collectionID) {
                    let us = results.filter { $0.collectionId == collectionID && $0.kind == "song" }
                    albumCache[key] = AlbumTracks(us: us.isEmpty ? [chosen] : us, local: local)
                    if let song = local.first(where: { $0.trackId == chosen.trackId }) { return Self.outcome(song) }
                }
            }
        }
        guard let songID, takeRequestSlot() else { return .retryLater }
        let query = ["id": songID, "country": Self.country, "lang": Self.prefersJapanese ? "ja_jp" : "en_us",
                     "media": "music"]
        guard let results = await request("lookup", query) else { return .retryLater }
        // 同じ曲でも、地域によってストアにない版がある（例：STAY のクリーン版は日本のストアにない）。
        // そのときは米国のストアで見つけた情報を使う（曲名は Sonos と同じ英語表記、アートワークは高画質）
        guard let found = results.first(where: { $0.kind == "song" }) ?? usSong else { return .notFound }
        return Self.outcome(found)
    }

    private static func outcome(_ song: Song) -> Outcome {
        guard let title = song.trackName, let artist = song.artistName else { return .notFound }
        return .found(CatalogMatch(title: title, artist: artist, album: song.collectionName,
                                   artworkURL: largeArtwork(song.artworkUrl100)))
    }

    /// アルバムの曲目から、Sonos が示す曲を探す
    /// 1. 米国のストアの表記（Sonos と同じローマ字）で曲名が一致する曲 → 同じ ID の地域の表記
    /// 2. 地域の表記で曲名が一致する曲（「Ham」のように日本語表記も同じ曲）
    /// 3. 長さが ±2 秒以内の曲がアルバム内にひとつだけなら、その曲
    private static func track(in album: AlbumTracks, title: String, duration: Double) -> Song? {
        let wanted = normalized(title)
        if let us = album.us.first(where: { $0.trackName.map(normalized) == wanted }) {
            return album.local.first { $0.trackId == us.trackId } ?? us
        }
        if let same = album.local.first(where: { $0.trackName.map(normalized) == wanted }) { return same }
        guard duration > 0 else { return nil }
        let close = album.local.filter { song in
            guard let millis = song.trackTimeMillis else { return false }
            return abs(Double(millis) / 1000 - duration) <= 2
        }
        return close.count == 1 ? close.first : nil
    }

    /// 端末の地域のストアでのアルバムの曲目
    private func localTracks(albumID: Int) async -> [Song]? {
        guard let tracks = await request("lookup", ["id": String(albumID), "entity": "song", "limit": "200",
                                                    "country": Self.country,
                                                    "lang": Self.prefersJapanese ? "ja_jp" : "en_us"])
        else { return nil }
        return tracks.filter { $0.kind == "song" && $0.trackId != nil }
    }

    /// 曲名が一致し、アーティストも合い、長さも ±3 秒以内の曲。`album` を渡すと、そのアルバムの版だけ
    private static func bestMatch(in songs: [Song], title: String, artist: String, duration: Double,
                                  album: String? = nil) -> Song? {
        let wanted = normalized(title)
        return songs.first { song in
            guard song.kind == "song", song.trackId != nil, let name = song.trackName,
                  normalized(name) == wanted else { return false }
            if let album, !sameAlbum(song, album) { return false }
            // 同名の別の曲（カバーなど）を避けるため、アーティストと長さも確かめる
            if let found = song.artistName, !sharesArtist(found, artist) { return false }
            if duration > 0, let millis = song.trackTimeMillis, abs(Double(millis) / 1000 - duration) > 3 { return false }
            return true
        }
    }

    /// Explicit の曲を、アーティストのアルバムの曲目から探す。
    /// 1. アーティスト ID を、検索結果（同じアーティストのほかの曲）かアーティスト検索から得る
    /// 2. アーティストのアルバム一覧（Explicit のアルバムも含まれる）を取る
    /// 3. Sonos が示すアルバム名と同じアルバムがあればその曲目を、なければアルバムをまとめて曲目を取り、曲名で照合する
    private enum FallbackResult {
        case found(Song, sameAlbum: Bool)
        case notFound
        case retryLater
    }

    private func explicitFallback(results: [Song], title: String, artist: String, album: String?,
                                  duration: Double) async -> FallbackResult {
        var artistID = results.first { song in
            song.artistName.map { Self.sharesArtist($0, artist) } ?? false
        }?.artistId
        if artistID == nil {
            guard takeRequestSlot() else { return .retryLater }
            let found = await request("search", ["term": Self.primaryArtist(artist), "entity": "musicArtist",
                                                 "limit": "5", "country": "us", "media": "music"])
            artistID = found?.first { $0.artistName.map { Self.sharesArtist($0, artist) } ?? false }?.artistId
        }
        guard let artistID else { return .notFound }
        guard takeRequestSlot() else { return .retryLater }
        guard let albums = await request("lookup", ["id": String(artistID), "entity": "album", "limit": "200",
                                                    "country": "us"])?.filter({ $0.collectionId != nil && $0.kind == nil })
        else { return .retryLater }

        var albumIDs = albums.compactMap(\.collectionId)
        var sameAlbumID: Int?
        if let album, let same = albums.first(where: { $0.collectionName.map(Self.normalized) == Self.normalized(album) }),
           let id = same.collectionId {
            albumIDs = [id]
            sameAlbumID = id
        }
        guard !albumIDs.isEmpty else { return .notFound }
        guard takeRequestSlot() else { return .retryLater }
        guard let tracks = await request("lookup", ["id": albumIDs.prefix(30).map(String.init).joined(separator: ","),
                                                    "entity": "song", "limit": "200", "country": "us"])
        else { return .retryLater }
        // アルバムが特定できたら、地域の表記の曲目も取ってまとめて覚える（同じアルバムのほかの曲は問い合わせ不要になる）。
        // 米国のストアにはアルバムの情報だけあって、曲が配信されていないこともある
        // （例：ずっと真夜中でいいのに。の「朗らかな皮膚とて不服」）。そのときも地域の曲目から曲名か長さで探せる
        if let sameAlbumID, let key = Self.albumKey(artist: artist, album: album) {
            guard takeRequestSlot() else { return .retryLater }
            guard let local = await localTracks(albumID: sameAlbumID) else { return .retryLater }
            let entry = AlbumTracks(us: tracks.filter { $0.kind == "song" && $0.trackId != nil }, local: local)
            albumCache[key] = entry
            guard let song = Self.track(in: entry, title: title, duration: duration) else { return .notFound }
            return .found(song, sameAlbum: true)
        }
        if let song = Self.bestMatch(in: tracks, title: title, artist: artist, duration: duration) {
            return .found(song, sameAlbum: Self.sameAlbum(song, album))
        }
        return .notFound
    }

    /// 曲が、Sonos が示すアルバムの版か（アルバム名が分からないときは問わない）
    private static func sameAlbum(_ song: Song, _ album: String?) -> Bool {
        guard let album, !normalized(album).isEmpty else { return true }
        return song.collectionName.map(normalized) == normalized(album)
    }

    /// 比較用：小文字にし、空白・記号の違いを無視する
    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// "A, B & C" のような連名でも、最初の名前が相手に含まれていれば同じアーティストとみなす
    private static func sharesArtist(_ a: String, _ b: String) -> Bool {
        let first = normalized(primaryArtist(b))
        return !first.isEmpty && normalized(a).contains(first)
    }

    private static func primaryArtist(_ artist: String) -> String {
        var result = artist
        for separator in [", ", " & ", " feat. ", " ft. ", " x ", " / "] {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 100×100 の画像URLを 1200×1200 に差し替える（Apple の画像サーバーは URL の大きさ指定で拡大版を返す）
    private static func largeArtwork(_ url: String?) -> URL? {
        guard let url, url.contains("100x100") else { return nil }
        return URL(string: url.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
            .replacingOccurrences(of: "100x100", with: "1200x1200"))
    }

    func removeAll() {
        cache.removeAll()
        albumCache.removeAll()
    }

    private func takeRequestSlot() -> Bool {
        let now = Date()
        recentRequests.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentRequests.count < maxRequestsPerMinute else { return false }
        recentRequests.append(now)
        return true
    }

    private struct Response: Decodable { let results: [Song] }
    private struct Song: Decodable {
        let kind: String?
        let trackId: Int?
        let artistId: Int?
        let collectionId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Int?
        let artworkUrl100: String?
    }

    private func request(_ path: String, _ query: [String: String]) async -> [Song]? {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.results
    }
}
