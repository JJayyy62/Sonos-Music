import Foundation
import SwiftUI

/// Sonos に登録して使う音楽ストリーミングサービス
///
/// Sonos は各サービスを「サービスID（sid）」で区別し、サービスタイプは `sid * 256 + 7` になる。
enum StreamingService: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleMusic
    case spotify
    case amazonMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .amazonMusic: return "Amazon Music"
        }
    }

    /// ラベル用の大文字表記
    var label: String { displayName.uppercased() }

    /// Sonos のサービスID
    var sonosServiceID: Int {
        switch self {
        case .appleMusic: return 204
        case .spotify: return 12
        case .amazonMusic: return 201
        }
    }

    /// Sonos のサービスタイプ（アカウント一覧・desc に出てくる番号）
    var sonosServiceType: Int { sonosServiceID * 256 + 7 }

    /// メタデータの desc に入れる既定値（実際のお気に入りから見つかればそちらを使う）
    var defaultDesc: String { "SA_RINCON\(sonosServiceType)_X_#Svc\(sonosServiceType)-0-Token" }

    /// サービスを見分けるための色（ロゴは使わず、色と名前だけで区別する）
    var tint: Color {
        switch self {
        case .appleMusic: return Color(red: 0.99, green: 0.36, blue: 0.45)
        case .spotify: return Color(red: 0.27, green: 0.86, blue: 0.47)
        case .amazonMusic: return Color(red: 0.25, green: 0.78, blue: 0.95)
        }
    }

    /// アプリ内でカタログを検索できるか
    var hasCatalogSearch: Bool { self != .amazonMusic }

    // MARK: Detection

    /// URI やメタデータからサービスを判定する
    static func detect(in text: String) -> StreamingService? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("x-sonos-spotify:") || lowered.contains("spotify%3a") || lowered.contains("spotify:") {
            return .spotify
        }
        for service in allCases {
            if lowered.contains("sid=\(service.sonosServiceID)&") || lowered.hasSuffix("sid=\(service.sonosServiceID)")
                || lowered.contains("sa_rincon\(service.sonosServiceType)_") {
                return service
            }
        }
        return nil
    }

    static func detect(_ item: DIDLItem) -> StreamingService? {
        if let uri = item.resURI, let service = detect(in: uri) { return service }
        if let resMD = item.resMD, let service = detect(in: resMD) { return service }
        if let desc = item.desc, let service = detect(in: desc) { return service }
        if let description = item.serviceDescription?.lowercased() {
            return allCases.first { description.contains($0.displayName.lowercased()) }
        }
        return nil
    }

    /// URIやメタデータに含まれるアカウント番号（sn=）
    func serial(in text: String) -> Int? {
        text.firstMatch("sid=\(sonosServiceID)[^\\s\"<]*?sn=(\\d+)").flatMap { Int($0) }
    }

    /// 実際に使われている desc（アカウントごとのトークン名）
    func desc(in text: String) -> String? {
        text.firstMatch("(SA_RINCON\(sonosServiceType)_[^<\"\\s&]*)")
    }
}

/// Sonos のアカウント情報（番号と desc）
struct ServiceAccount: Equatable, Sendable {
    var serial: Int
    var desc: String
}

/// サービスのカタログ上の曲・アルバム・プレイリスト
struct ServiceContent: Hashable, Sendable {
    enum Kind: String, Sendable { case track, album, playlist }

    var service: StreamingService
    var kind: Kind
    /// サービス上のID（Amazon の曲は "曲ASIN" と "アルバムASIN" を `albumID` に分けて持つ）
    var id: String
    var title: String
    var albumID: String?

    static func song(_ service: StreamingService, id: String, title: String, albumID: String? = nil) -> ServiceContent {
        ServiceContent(service: service, kind: .track, id: id, title: title, albumID: albumID)
    }
    static func album(_ service: StreamingService, id: String, title: String) -> ServiceContent {
        ServiceContent(service: service, kind: .album, id: id, title: title)
    }
    static func playlist(_ service: StreamingService, id: String, title: String) -> ServiceContent {
        ServiceContent(service: service, kind: .playlist, id: id, title: title)
    }
}

/// ServiceContent から Sonos に渡す URI / メタデータの候補を作る（先頭から順に試す）
enum SonosServiceURI {
    typealias Candidate = (uri: String, metadata: String)

    static func candidates(for content: ServiceContent, account: ServiceAccount) -> [Candidate] {
        switch content.service {
        case .appleMusic: return appleMusic(content, account)
        case .spotify: return spotify(content, account)
        case .amazonMusic: return amazon(content, account)
        }
    }

    private static func meta(_ id: String, parent: String, _ content: ServiceContent, _ upnpClass: String, _ account: ServiceAccount) -> String {
        DIDL.metadata(id: id, parentID: parent, title: content.title, upnpClass: upnpClass,
                      desc: account.desc, isContainer: false)
    }

    private static let trackClass = "object.item.audioItem.musicTrack"
    private static let albumClass = "object.container.album.musicAlbum"
    private static let playlistClass = "object.container.playlistContainer"

    // MARK: Apple Music（sid 204）

    private static func appleMusic(_ content: ServiceContent, _ account: ServiceAccount) -> [Candidate] {
        let sid = StreamingService.appleMusic.sonosServiceID
        switch content.kind {
        case .track:
            let encoded = "song%3a\(content.id)"
            return [("x-sonos-http:\(encoded).mp4?sid=\(sid)&flags=8224&sn=\(account.serial)",
                     meta("10032020\(encoded)", parent: "1004206calbum%3a", content, trackClass, account))]
        case .album:
            return ["1004206c", "0004206c"].flatMap { prefix -> [Candidate] in
                let objectID = "\(prefix)album%3a\(content.id)"
                let metadata = meta(objectID, parent: "00020000album%3a", content, albumClass, account)
                return [("x-rincon-cpcontainer:\(objectID)?sid=\(sid)&flags=8300&sn=\(account.serial)", metadata),
                        ("x-rincon-cpcontainer:\(objectID)", metadata)]
            }
        case .playlist:
            // カタログのプレイリスト（pl.）と、自分のライブラリのプレイリスト（p.）で ID の形が違う
            let path = content.id.hasPrefix("p.") ? "libraryplaylist%3a" : "playlist%3a"
            let objectID = "1006206c\(path)\(content.id)"
            return [("x-rincon-cpcontainer:\(objectID)?sid=\(sid)&flags=8300&sn=\(account.serial)",
                     meta(objectID, parent: objectID, content, playlistClass, account))]
        }
    }

    // MARK: Spotify（sid 12）

    private static func spotify(_ content: ServiceContent, _ account: ServiceAccount) -> [Candidate] {
        let sid = StreamingService.spotify.sonosServiceID
        let encoded = "spotify%3a\(content.kind.rawValue)%3a\(content.id)"
        switch content.kind {
        case .track:
            return [("x-sonos-spotify:\(encoded)?sid=\(sid)&flags=8224&sn=\(account.serial)",
                     meta("00032020\(encoded)", parent: "", content, trackClass, account))]
        case .album:
            return ["1004206c", "0004206c"].map { prefix in
                ("x-rincon-cpcontainer:\(prefix)\(encoded)?sid=\(sid)&flags=8300&sn=\(account.serial)",
                 meta("\(prefix)\(encoded)", parent: "", content, albumClass, account))
            }
        case .playlist:
            return ["1006206c", "0006206c"].map { prefix in
                ("x-rincon-cpcontainer:\(prefix)\(encoded)?sid=\(sid)&flags=8300&sn=\(account.serial)",
                 meta("\(prefix)\(encoded)", parent: "", content, playlistClass, account))
            }
        }
    }

    // MARK: Amazon Music（sid 201）

    private static func amazon(_ content: ServiceContent, _ account: ServiceAccount) -> [Candidate] {
        let sid = StreamingService.amazonMusic.sonosServiceID
        switch content.kind {
        case .track:
            var path = "catalog%2ftracks%2f\(content.id)%2f"
            if let albumID = content.albumID { path += "%3falbumAsin%3d\(albumID)" }
            return [
                ("x-sonosapi-hls-static:\(path)?sid=\(sid)&flags=0&sn=\(account.serial)",
                 meta("10030000\(path)", parent: "", content, trackClass, account)),
                ("x-sonos-http:\(path)?sid=\(sid)&flags=8224&sn=\(account.serial)",
                 meta("10032020\(path)", parent: "", content, trackClass, account)),
            ]
        case .album:
            let path = "catalog%2falbums%2f\(content.id)%2f%23album_desc"
            return ["1004206c", "0004206c"].map { prefix in
                ("x-rincon-cpcontainer:\(prefix)\(path)?sid=\(sid)&flags=8300&sn=\(account.serial)",
                 meta("\(prefix)\(path)", parent: "", content, albumClass, account))
            }
        case .playlist:
            let path = "catalog%2fplaylists%2f\(content.id)%2f%23playlist_desc"
            return ["1006206c", "0006206c"].map { prefix in
                ("x-rincon-cpcontainer:\(prefix)\(path)?sid=\(sid)&flags=8300&sn=\(account.serial)",
                 meta("\(prefix)\(path)", parent: "", content, playlistClass, account))
            }
        }
    }
}

// MARK: - Share links

/// 各サービスの共有リンク（「リンクをコピー」で得られるURL）から再生対象を取り出す
enum ServiceLink {
    static func parse(_ text: String) -> ServiceContent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) ?? firstURL(in: trimmed),
              let host = url.host?.lowercased() else {
            return spotifyURI(trimmed)
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        if host.hasSuffix("spotify.com") {
            // https://open.spotify.com/(intl-ja/)track/{id}
            for kind in [ServiceContent.Kind.track, .album, .playlist] {
                if let index = parts.firstIndex(of: kind.rawValue), parts.indices.contains(index + 1) {
                    return ServiceContent(service: .spotify, kind: kind, id: parts[index + 1], title: "Spotify")
                }
            }
        } else if host.hasPrefix("music.apple.com") || host.hasSuffix(".music.apple.com") {
            // https://music.apple.com/jp/album/{name}/{id}?i={songID}
            if let songID = value("i") { return .song(.appleMusic, id: songID, title: "Apple Music") }
            if let index = parts.firstIndex(of: "song"), let id = parts.last, index < parts.count - 1 {
                return .song(.appleMusic, id: id, title: "Apple Music")
            }
            if parts.contains("album"), let id = parts.last { return .album(.appleMusic, id: id, title: "Apple Music") }
            if parts.contains("playlist"), let id = parts.last { return .playlist(.appleMusic, id: id, title: "Apple Music") }
        } else if host.contains("amazon.") {
            // https://music.amazon.co.jp/albums/{albumASIN}?trackAsin={trackASIN}
            if let albumIndex = parts.firstIndex(of: "albums"), parts.indices.contains(albumIndex + 1) {
                let album = parts[albumIndex + 1]
                if let track = value("trackAsin") ?? value("trackasin") {
                    return .song(.amazonMusic, id: track, title: "Amazon Music", albumID: album)
                }
                return .album(.amazonMusic, id: album, title: "Amazon Music")
            }
            if let index = parts.firstIndex(where: { $0 == "playlists" || $0 == "user-playlists" }),
               parts.indices.contains(index + 1) {
                return .playlist(.amazonMusic, id: parts[index + 1], title: "Amazon Music")
            }
            if let index = parts.firstIndex(of: "tracks"), parts.indices.contains(index + 1) {
                return .song(.amazonMusic, id: parts[index + 1], title: "Amazon Music")
            }
        }
        return nil
    }

    /// spotify:track:xxxx 形式
    private static func spotifyURI(_ text: String) -> ServiceContent? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "spotify",
              let kind = ServiceContent.Kind(rawValue: parts[1]) else { return nil }
        return ServiceContent(service: .spotify, kind: kind, id: parts[2], title: "Spotify")
    }

    /// 共有テキスト（「〇〇を聴こう https://...」など）の中からURLを探す
    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }
}
