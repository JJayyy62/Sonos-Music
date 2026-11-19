import Foundation
import Observation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String

    var isInterlude: Bool { text.isEmpty }

    /// time 以前で最後に始まった行
    static func activeIndex(in lines: [LyricLine], at time: Double) -> Int? {
        var low = 0, high = lines.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}

// MARK: - LRC parser

enum LRCParser {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordTimestamp = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var entries: [(time: Double, text: String)] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {
                let value = line.dropFirst(8).prefix { $0 != "]" }
                offset = (Double(value.trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            var cursor = 0
            var times: [Double] = []
            for match in matches where match.range.location == cursor {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let digits = ns.substring(with: fractionRange)
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                cursor = match.range.location + match.range.length
            }
            guard !times.isEmpty else { continue }

            var content = ns.substring(from: cursor)
            content = wordTimestamp.stringByReplacingMatches(
                in: content, range: NSRange(location: 0, length: (content as NSString).length), withTemplate: "")
            content = content.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((max(0, time - offset), content)) }
        }

        entries.sort { $0.time < $1.time }
        // 前奏が長い場合は先頭にインタールード（•••）を入れる
        if let first = entries.first, first.time > 4, !first.text.isEmpty {
            entries.insert((0, ""), at: 0)
        }
        return entries.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}

// MARK: - LRCLIB

/// https://lrclib.net の無料API（同期歌詞）
enum LRCLIBClient {
    struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let base = "https://lrclib.net/api"

    static func lookup(title: String, artist: String, album: String, duration: Double) async -> LyricsStore.State {
        do {
            if !album.isEmpty, duration > 0,
               let record = try await get(title: title, artist: artist, album: album, duration: duration),
               let state = state(from: record) {
                return state
            }
            let cleanTitle = clean(title)
            let mainArtist = primaryArtist(artist)
            var candidates = try await search(["track_name": cleanTitle, "artist_name": mainArtist])
            if candidates.isEmpty {
                candidates = try await search(["q": "\(cleanTitle) \(mainArtist)"])
            }
            if let best = pickBest(candidates, duration: duration), let state = state(from: best) {
                return state
            }
            return .notFound
        } catch is CancellationError {
            return .idle
        } catch {
            return .failed
        }
    }

    private static func state(from record: Record) -> LyricsStore.State? {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        if record.instrumental == true { return .instrumental }
        return nil
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async throws -> Record? {
        let data = try await request("/get", [
            "track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded())),
        ])
        guard let data else { return nil }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(_ query: [String: String]) async throws -> [Record] {
        guard let data = try await request("/search", query) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func request(_ path: String, _ query: [String: String]) async throws -> Data? {
        guard var components = URLComponents(string: base + path) else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" はサーバー側で空白扱いになるため明示的にエンコードする
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Aria/1.0 (Sonos music player for iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func pickBest(_ records: [Record], duration: Double) -> Record? {
        let usable = records.filter { ($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false) }
        func score(_ r: Record) -> Double {
            var s = 0.0
            if r.syncedLyrics?.isEmpty == false { s += 100 }
            if duration > 0, let d = r.duration {
                let diff = abs(d - duration)
                s -= diff
                if diff > 8 { s -= 200 }
            }
            return s
        }
        return usable.max { score($0) < score($1) }
    }

    static func clean(_ title: String) -> String {
        var t = title
        let patterns = [
            #"\s*[\(\[（【][^\)\]）】]*(feat|ft\.|with |remaster|version|ver\.|edit|mix|live|mono|stereo|bonus|single|from)[^\)\]）】]*[\)\]）】]"#,
            #"\s+-\s+.*(remaster|version|edit|mix|live|mono|single).*$"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                t = regex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            }
        }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " ft. ", "、", " x ", " × ", " / "]
        var result = artist
        for separator in separators {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Store

@Observable @MainActor
final class LyricsStore {
    enum State: Equatable {
        case idle, loading
        case synced([LyricLine])
        case plain([String])
        case instrumental, notFound, failed
    }

    private(set) var state: State = .idle
    /// 常にかける基準の補正（秒）。Sonos の再生位置の取得遅れを見込んで歌詞を少し早めに進める。
    /// 画面に出す補正値はこれを 0.0 として表す
    static let baseOffset = 0.6

    /// 利用者が設定する補正（秒、基準からの差）。プラスで歌詞が早く進む
    private(set) var offset: Double = LyricsStore.loadOffset()

    /// 実際に歌詞の表示にかける補正（基準 + 利用者の補正）
    var timingOffset: Double { Self.baseOffset + offset }

    private static let offsetKey = "lyricsOffsetAdjustment"

    /// 以前の保存値（"lyricsOffset" は実際にかける補正そのもの）があれば、基準からの差に置き換えて引き継ぐ
    private static func loadOffset() -> Double {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: offsetKey) as? Double { return value }
        guard let legacy = defaults.object(forKey: "lyricsOffset") as? Double else { return 0 }
        let migrated = ((legacy - baseOffset) * 10).rounded() / 10
        defaults.set(migrated, forKey: offsetKey)
        defaults.removeObject(forKey: "lyricsOffset")
        return migrated
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var currentKey: String?
    @ObservationIgnored private var lastRequest: (title: String, artist: String, album: String, duration: Double)?

    var hasSyncedLyrics: Bool {
        if case .synced = state { return true }
        return false
    }

    func setOffset(_ value: Double) {
        offset = (value * 10).rounded() / 10
        UserDefaults.standard.set(offset, forKey: Self.offsetKey)
    }

    func load(title: String, artist: String, album: String, duration: Double) {
        let key = "\(title)|\(artist)".lowercased()
        guard key != currentKey else { return }
        currentKey = key
        lastRequest = (title, artist, album, duration)
        task?.cancel()

        guard !title.isEmpty else { state = .idle; return }
        if let cached = cache[key] { state = cached; return }

        state = .loading
        task = Task { [weak self] in
            let result = await LRCLIBClient.lookup(title: title, artist: artist, album: album, duration: duration)
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            if result != .failed && result != .idle { self.cache[key] = result }
            self.state = result
        }
    }

    func retry() {
        guard let request = lastRequest else { return }
        currentKey = nil
        load(title: request.title, artist: request.artist, album: request.album, duration: request.duration)
    }

    func clear() {
        task?.cancel()
        currentKey = nil
        state = .idle
    }
}
