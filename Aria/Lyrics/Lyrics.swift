import Foundation
import Observation

/// 単語（音節）単位の歌詞
struct LyricWord: Equatable, Sendable, Codable {
    let start: Double
    let end: Double
    var text: String

    func progress(at time: Double) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }
}

struct LyricLine: Identifiable, Equatable, Sendable, Codable {
    enum Side: String, Sendable, Codable { case leading, trailing }

    let id: Int
    let time: Double
    let text: String
    var endTime: Double?
    /// 単語単位のタイミング（行単位の歌詞では空）
    var words: [LyricWord]
    /// バックコーラス
    var background: [LyricWord]
    var backgroundText: String
    /// デュエットで2人目の歌い手は右寄せ
    var side: Side
    /// 翻訳（Apple Music のように原文の下に小さく出す）
    var translation: String?

    init(id: Int, time: Double, text: String, endTime: Double? = nil, words: [LyricWord] = [],
         background: [LyricWord] = [], backgroundText: String = "", side: Side = .leading,
         translation: String? = nil) {
        self.id = id
        self.time = time
        self.text = text
        self.endTime = endTime
        self.words = words
        self.background = background
        self.backgroundText = backgroundText
        self.side = side
        self.translation = translation
    }

    /// 「原文^翻訳」のように1行に続けて入っている翻訳を、原文と翻訳に分ける。
    /// 単語単位の歌詞では "^" を含む単語で切り、それ以降の単語を翻訳として扱う
    func separatingInlineTranslation() -> LyricLine {
        guard let caret = text.firstIndex(of: "^") else { return self }
        let original = text[..<caret].trimmingCharacters(in: .whitespacesAndNewlines)
        let inline = text[text.index(after: caret)...].trimmingCharacters(in: .whitespacesAndNewlines)

        var keptWords = words
        if let index = words.firstIndex(where: { $0.text.contains("^") }) {
            keptWords = Array(words[..<index])
            var word = words[index]
            if let wordCaret = word.text.firstIndex(of: "^") {
                word.text = String(word.text[..<wordCaret])
                if !word.text.trimmingCharacters(in: .whitespaces).isEmpty { keptWords.append(word) }
            }
            if let last = keptWords.indices.last {
                keptWords[last].text = keptWords[last].text.replacingOccurrences(
                    of: #"\s+$"#, with: "", options: .regularExpression)
            }
        }
        var line = LyricLine(id: id, time: time, text: original, endTime: endTime, words: keptWords,
                             background: background, backgroundText: backgroundText, side: side,
                             translation: translation)
        if line.translation == nil, !inline.isEmpty { line.translation = inline }
        return line
    }

    var isInterlude: Bool { text.isEmpty && backgroundText.isEmpty }
    var isWordSynced: Bool { !words.isEmpty }

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

    /// 時刻順に並べ、前奏と長い間奏に「•••」の行を入れて、IDを振り直す
    static func finalize(_ input: [LyricLine]) -> [LyricLine] {
        let sorted = input.map { $0.separatingInlineTranslation() }.sorted { $0.time < $1.time }
        var result: [LyricLine] = []
        if let first = sorted.first, first.time > 4, !first.isInterlude {
            result.append(LyricLine(id: 0, time: 0, text: ""))
        }
        for (index, line) in sorted.enumerated() {
            result.append(line)
            guard !line.isInterlude, let end = line.endTime, index + 1 < sorted.count else { continue }
            if sorted[index + 1].time - end > 5 {
                result.append(LyricLine(id: 0, time: end, text: ""))
            }
        }
        return result.enumerated().map { offset, line in
            LyricLine(id: offset, time: line.time, text: line.text, endTime: line.endTime, words: line.words,
                      background: line.background, backgroundText: line.backgroundText, side: line.side,
                      translation: line.translation)
        }
    }
}

// MARK: - LRC parser

enum LRCParser {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordTimestamp = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var entries: [(time: Double, text: String, words: [LyricWord])] = []

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

            let raw = ns.substring(from: cursor)
            let words = wordTimed(raw, offset: offset)
            var content = wordTimestamp.stringByReplacingMatches(
                in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
            // 単語ごとの時刻がある行は、日本語の文字間の空白を詰めた単語から行の文字列を作る
            if !words.isEmpty { content = words.map(\.text).joined() }
            content = content.trimmingCharacters(in: .whitespaces)
            // 単語ごとの時刻は1つ目の行時刻にだけ対応しているので、時刻が複数ある行では使わない
            for time in times {
                entries.append((max(0, time - offset), content, times.count == 1 ? words : []))
            }
        }

        return LyricLine.finalize(entries.map { LyricLine(id: 0, time: $0.time, text: $0.text, words: $0.words) })
    }

    /// Enhanced LRC の単語ごとの時刻（"<00:12.00>First <00:12.60>line <00:13.10>"）を単語の一覧にする。
    /// 各単語は次の時刻タグまで続く。最後のタグの後に文字がなければ、それは直前の単語の終わりを表す
    private static func wordTimed(_ raw: String, offset: Double) -> [LyricWord] {
        let ns = raw as NSString
        let matches = wordTimestamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        func seconds(_ match: NSTextCheckingResult) -> Double {
            let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let secs = Double(ns.substring(with: match.range(at: 2))) ?? 0
            var fraction = 0.0
            if match.range(at: 3).location != NSNotFound {
                let digits = ns.substring(with: match.range(at: 3))
                fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            }
            return max(0, minutes * 60 + secs + fraction - offset)
        }
        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            var text = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            if words.isEmpty { text = String(text.drop { $0.isWhitespace }) }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let start = seconds(match)
            let end = index + 1 < matches.count ? seconds(matches[index + 1]) : start + 1
            words.append(LyricWord(start: start, end: max(end, start), text: text))
        }
        // Enhanced LRC は単語を空白で区切るので、日本語・中国語では1文字ごとに空白が入ってしまう。
        // 前後がどちらも日本語・中国語の文字なら、その空白を取り除く
        for index in words.indices.dropLast() where words[index].text.last?.isWhitespace == true {
            let body = words[index].text.trimmingCharacters(in: .whitespaces)
            if let left = body.last, let right = words[index + 1].text.first,
               isCJK(left), isCJK(right) {
                words[index].text = body
            }
        }
        if let last = words.indices.last {
            words[last].text = String(words[last].text.reversed().drop { $0.isWhitespace }.reversed())
        }
        return words
    }

    /// ひらがな・カタカナ・漢字・全角の句読点など
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Sources

enum LyricsSource: String, Sendable, Codable {
    case betterLyrics = "Better Lyrics"
    case lrclib = "LRCLIB"
    case karalyr = "Karalyr"
}

enum LyricsService {
    /// 以前は設定で取得元を選べたが、ややこしいので固定の順番にした。古い設定値が残っていても使わないよう消す
    static func removeLegacySourceSettings() {
        for key in ["useBetterLyrics", "debug.disableLRCLIB", "debug.disableKaralyr"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 歌詞を探す順番（単語ごとの時刻がある歌詞を優先する）
    /// 1. Better Lyrics の単語単位の歌詞
    /// 2. Karalyr の単語単位の歌詞（Karalyr は単語単位の歌詞だけを持つ）
    /// 3. Better Lyrics の行単位の歌詞
    /// 4. LRCLIB（行単位、時刻なしの歌詞も）
    /// Better Lyrics と Karalyr は同時に問い合わせて、待ち時間を増やさない
    static func lookup(title: String, artist: String, album: String, duration: Double) async -> (LyricsStore.State, LyricsSource?) {
        async let better: [LyricLine]? = betterLyrics(title, artist, album, duration)
        async let karaoke: [LyricLine]? = karalyr(title, artist, album, duration)

        let betterLines = await better
        if let betterLines, betterLines.contains(where: \.isWordSynced) { return (.synced(betterLines), .betterLyrics) }
        let karaokeLines = await karaoke
        if Task.isCancelled { return (.idle, nil) }
        if let karaokeLines { return (.synced(karaokeLines), .karalyr) }
        if let betterLines { return (.synced(betterLines), .betterLyrics) }

        let state = await LRCLIBClient.lookup(title: title, artist: artist, album: album, duration: duration)
        switch state {
        case .synced, .plain, .instrumental: return (state, .lrclib)
        default: return (state, nil)
        }
    }

    private static func betterLyrics(_ title: String, _ artist: String, _ album: String, _ duration: Double) async -> [LyricLine]? {
        if case .found(let lines) = await BetterLyricsClient.fetch(title: title, artist: artist, album: album, duration: duration) {
            return lines
        }
        return nil
    }

    /// Karalyr の歌詞のうち、単語ごとの時刻が付いているものだけを返す
    private static func karalyr(_ title: String, _ artist: String, _ album: String, _ duration: Double) async -> [LyricLine]? {
        let state = await LRCLIBClient.lookup(title: title, artist: artist, album: album, duration: duration, server: .karalyr)
        guard case .synced(let lines) = state, lines.contains(where: \.isWordSynced) else { return nil }
        return lines
    }
}

// MARK: - LRCLIB

/// https://lrclib.net の無料API（同期歌詞）。
/// LRCLIB 互換の API を持つ Karalyr（https://www.karalyr.com）にも、接続先を替えて使う
enum LRCLIBClient {
    /// 接続先。どちらも同じ形の /get と /search を持つ
    struct Server: Sendable {
        let base: String
        let headers: [String: String]

        static let lrclib = Server(base: "https://lrclib.net/api", headers: [:])
        /// 単語ごとの時刻付きの歌詞だけを持つカラオケ歌詞データベース。
        /// どのアプリからの利用か分かるように X-Karalyr-Client を付ける（任意のヘッダー）
        static let karalyr = Server(base: "https://www.karalyr.com/api", headers: ["X-Karalyr-Client": "Aria/1.0"])
    }

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

    static func lookup(title: String, artist: String, album: String, duration: Double,
                       server: Server = .lrclib) async -> LyricsStore.State {
        do {
            if !album.isEmpty, duration > 0,
               let record = try await get(title: title, artist: artist, album: album, duration: duration, server: server),
               let state = state(from: record) {
                return state
            }
            let cleanTitle = clean(title)
            let mainArtist = primaryArtist(artist)
            var candidates = try await search(["track_name": cleanTitle, "artist_name": mainArtist], server: server)
            if candidates.isEmpty {
                candidates = try await search(["q": "\(cleanTitle) \(mainArtist)"], server: server)
            }
            if let best = pickBest(candidates, duration: duration) {
                if let state = state(from: best) { return state }
                // Karalyr の検索結果には歌詞の本文が入っていないので、ID で取り直す
                if let full = try await record(id: best.id, server: server), let state = state(from: full) {
                    return state
                }
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

    private static func get(title: String, artist: String, album: String, duration: Double,
                            server: Server) async throws -> Record? {
        let data = try await request("/get", [
            "track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded())),
        ], server: server)
        guard let data else { return nil }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private static func record(id: Int, server: Server) async throws -> Record? {
        guard let data = try await request("/get/\(id)", [:], server: server) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(_ query: [String: String], server: Server) async throws -> [Record] {
        guard let data = try await request("/search", query, server: server) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func request(_ path: String, _ query: [String: String], server: Server) async throws -> Data? {
        guard var components = URLComponents(string: server.base + path) else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" はサーバー側で空白扱いになるため明示的にエンコードする
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Aria/1.0 (Sonos music player for iOS)", forHTTPHeaderField: "User-Agent")
        for (field, value) in server.headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func pickBest(_ records: [Record], duration: Double) -> Record? {
        let withLyrics = records.filter { ($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false) }
        // Karalyr の検索結果は歌詞の本文を含まないので、そのときは長さの近さだけで選ぶ（本文はあとで ID で取る）
        let usable = withLyrics.isEmpty ? records.filter { r in
            guard duration > 0, let d = r.duration else { return true }
            return abs(d - duration) <= 8
        } : withLyrics
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
    private(set) var source: LyricsSource?
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
    @ObservationIgnored private var cache: [String: (State, LyricsSource?)] = [:]
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

    /// 端末に保存するときのキー。取得元の設定ごとに分ける
    private static func diskKey(_ key: String) -> String {
        "v2|\(key)"
    }

    func load(title: String, artist: String, album: String, duration: Double) {
        let key = "\(title)|\(artist)".lowercased()
        guard key != currentKey else { return }
        currentKey = key
        lastRequest = (title, artist, album, duration)
        task?.cancel()

        guard !title.isEmpty else {
            state = .idle
            source = nil
            return
        }
        if let cached = cache[key] {
            (state, source) = cached
            return
        }

        state = .loading
        source = nil
        let diskKey = Self.diskKey(key)
        task = Task { [weak self] in
            // 端末に保存してあれば、通信せずにそれを使う
            if let saved = await LyricsDiskCache.shared.load(diskKey) {
                guard let self, !Task.isCancelled, self.currentKey == key else { return }
                self.cache[key] = saved
                (self.state, self.source) = saved
                return
            }
            let (result, source) = await LyricsService.lookup(title: title, artist: artist, album: album, duration: duration)
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            if result != .failed && result != .idle {
                self.cache[key] = (result, source)
                await LyricsDiskCache.shared.save(diskKey, state: result, source: source)
            }
            self.state = result
            self.source = source
        }
    }

    func retry() {
        guard let request = lastRequest else { return }
        let key = "\(request.title)|\(request.artist)".lowercased()
        cache[key] = nil
        let diskKey = Self.diskKey(key)
        currentKey = nil
        // 保存してある結果を消し終えてから取り直す（先に読むと、消す前の古い結果を使ってしまう）
        Task {
            await LyricsDiskCache.shared.remove(diskKey)
            self.load(title: request.title, artist: request.artist, album: request.album, duration: request.duration)
        }
    }

    func clear() {
        task?.cancel()
        currentKey = nil
        state = .idle
        source = nil
    }

    /// メモリと端末に保存した歌詞をすべて消して、いまの曲の歌詞を取り直す
    func clearAllCaches() async {
        cache.removeAll()
        await LyricsDiskCache.shared.removeAll()
        guard let request = lastRequest else { return }
        currentKey = nil
        load(title: request.title, artist: request.artist, album: request.album, duration: request.duration)
    }
}
