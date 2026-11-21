import CryptoKit
import Foundation

/// 歌詞を端末（Library/Caches/Lyrics）に保存して、アプリを開き直しても通信なしで表示できるようにする。
///
/// - 見つかった歌詞は 30 日、「見つからなかった」「インストゥルメンタル」は 1 日で期限切れにする
///   （あとから歌詞が追加・改善されたときに取り直せるように）
/// - 取得元の設定（Better Lyrics・LRCLIB・Karalyr のオン・オフ）ごとに別々に保存する。
///   設定を変えたときに、別の設定で取った結果を使ってしまわないため
/// - Caches フォルダなので、端末の空きが少ないときは iOS が消すことがある
actor LyricsDiskCache {
    static let shared = LyricsDiskCache()

    private static let foundLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let missLifetime: TimeInterval = 24 * 60 * 60

    private struct Entry: Codable {
        enum Kind: String, Codable { case synced, plain, instrumental, notFound }
        var kind: Kind
        var lines: [LyricLine]?
        var plain: [String]?
        var source: LyricsSource?
        var savedAt: Date
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lyrics", isDirectory: true)
    }()

    private func fileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    /// 保存してある歌詞。なければ、または期限切れなら nil
    func load(_ key: String) -> (LyricsStore.State, LyricsSource?)? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        let lifetime = (entry.kind == .synced || entry.kind == .plain) ? Self.foundLifetime : Self.missLifetime
        guard Date().timeIntervalSince(entry.savedAt) < lifetime else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        switch entry.kind {
        case .synced: return entry.lines.map { (.synced($0), entry.source) }
        case .plain: return entry.plain.map { (.plain($0), entry.source) }
        case .instrumental: return (.instrumental, entry.source)
        case .notFound: return (.notFound, nil)
        }
    }

    /// 結果を保存する（読み込み中・通信エラーは保存しない）
    func save(_ key: String, state: LyricsStore.State, source: LyricsSource?) {
        let entry: Entry
        switch state {
        case .synced(let lines): entry = Entry(kind: .synced, lines: lines, source: source, savedAt: Date())
        case .plain(let lines): entry = Entry(kind: .plain, plain: lines, source: source, savedAt: Date())
        case .instrumental: entry = Entry(kind: .instrumental, source: source, savedAt: Date())
        case .notFound: entry = Entry(kind: .notFound, savedAt: Date())
        case .idle, .loading, .failed: return
        }
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// 保存してある歌詞の件数と合計サイズ（バイト）
    func usage() -> (count: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, bytes)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
