import Foundation

/// 曲名・アーティスト名・アルバム名の表示用（日本語など、端末の言語での表記）
struct TrackNames: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
}

/// Sonos が英語表記（ローマ字）で返す Apple Music の曲名を、Apple のカタログで引いて端末の言語の表記にする。
///
/// 例: "Arukuaround / sakanaction" → 「アルクアラウンド / サカナクション」
/// - カタログの曲IDが分かる曲は ID で引く
/// - 分からない曲（ライブラリの曲）は「曲名 アーティスト名」で検索し、長さが ±3 秒以内のものだけ採用する
/// - 結果が元の表記と同じ（英語の曲など）なら何もしない
actor TrackNameLocalizer {
    static let shared = TrackNameLocalizer()

    /// 調べた結果（nil は「置き換える表記なし」）。回数制限や通信エラーで調べられなかった曲は入れない
    private var cache: [String: TrackNames?] = [:]
    private var inflight: [String: Task<Outcome, Never>] = [:]

    private enum Outcome {
        case found(TrackNames)
        case unchanged
        case retryLater
    }
    /// iTunes Search API は 1 分あたり 20 回程度までなので、それを超えないように間隔をあける
    private var recentRequests: [Date] = []
    private let maxRequestsPerMinute = 18

    private static var language: String? {
        Locale.current.language.languageCode?.identifier == "ja" ? "ja_jp" : nil
    }

    private static var country: String {
        (Locale.current.region?.identifier ?? "JP").lowercased()
    }

    /// 端末の言語が日本語で、元の表記がすべて英数字（ローマ字）のときだけ調べる
    static func needsLookup(title: String, artist: String) -> Bool {
        guard language != nil, !title.isEmpty else { return false }
        return (title + artist).unicodeScalars.allSatisfy(\.isASCII)
    }

    func names(title: String, artist: String, album: String?, duration: Double,
               catalogSongID: String?) async -> TrackNames? {
        guard Self.needsLookup(title: title, artist: artist) else { return nil }
        let key = catalogSongID.map { "id:\($0)" } ?? "q:\(title)|\(artist)|\(Int(duration))".lowercased()
        if let cached = cache[key] { return cached }
        if let running = inflight[key] {
            if case .found(let names) = await running.value { return names }
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
        case .found(let names):
            cache[key] = names
            return names
        case .unchanged:
            cache[key] = .some(nil)
            return nil
        case .retryLater:
            return nil
        }
    }

    private func lookup(title: String, artist: String, album: String?, duration: Double,
                        catalogSongID: String?) async -> Outcome {
        guard let language = Self.language else { return .unchanged }
        guard takeRequestSlot() else { return .retryLater }

        var query = ["country": Self.country, "lang": language, "media": "music"]
        let path: String
        if let catalogSongID {
            path = "lookup"
            query["id"] = catalogSongID
        } else {
            path = "search"
            query["term"] = "\(title) \(artist)"
            query["entity"] = "song"
            query["limit"] = "8"
        }
        guard let results = await request(path, query) else { return .retryLater }
        let songs = results.filter { $0.kind == "song" }

        let match: Song?
        if catalogSongID != nil {
            match = songs.first
        } else {
            // 長さで照合し、別の曲を取り違えないようにする
            guard duration > 0 else { return .unchanged }
            let candidates = songs.filter { song in
                guard let millis = song.trackTimeMillis else { return false }
                return abs(Double(millis) / 1000 - duration) <= 3
            }
            match = candidates.first { $0.collectionName?.lowercased() == album?.lowercased() } ?? candidates.first
        }
        guard let match, let newTitle = match.trackName, let newArtist = match.artistName else { return .unchanged }
        // 表記が変わらないなら置き換える意味がない
        guard newTitle != title || newArtist != artist else { return .unchanged }
        return .found(TrackNames(title: newTitle, artist: newArtist, album: match.collectionName ?? album))
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
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Int?
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
