import Foundation
import SwiftUI

/// Sonos に登録して使う音楽ストリーミングサービス
///
/// Sonos は各サービスを「サービスID（sid）」で区別し、サービスタイプは `sid * 256 + 7` になる。
enum StreamingService: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleMusic
    case spotify

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// ラベル用の大文字表記
    var label: String { displayName.uppercased() }

    /// Sonos のサービスID
    var sonosServiceID: Int {
        switch self {
        case .appleMusic: return 204
        case .spotify: return 12
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
        }
    }

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
    /// サービス上のID
    var id: String
    var title: String

    static func song(_ service: StreamingService, id: String, title: String) -> ServiceContent {
        ServiceContent(service: service, kind: .track, id: id, title: title)
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
            // カタログのアルバム（数字の ID）と、自分のライブラリのアルバム（l.）で ID の形が違う
            let path = content.id.hasPrefix("l.") ? "libraryalbum%3a" : "album%3a"
            return ["1004206c", "0004206c"].flatMap { prefix -> [Candidate] in
                let objectID = "\(prefix)\(path)\(content.id)"
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

    /// 実際の Sonos のお気に入り（Spotify のアルバム）では次の形だった。これに合わせ、合わない場合に備えて従来の形も試す
    /// `x-rincon-cpcontainer:1006206cspotify%3Aalbum%3A<ID>?sid=12&flags=8300&sn=<番号>`
    /// （メタデータの id も同じ、parentID は id と同じ、class は playlistContainer、desc は `SA_RINCON3079_X_#Svc3079-<トークン>-Token`）
    private static func spotify(_ content: ServiceContent, _ account: ServiceAccount) -> [Candidate] {
        let sid = StreamingService.spotify.sonosServiceID
        let encoded = "spotify%3A\(content.kind.rawValue)%3A\(content.id)"
        let query = "sid=\(sid)&flags=8300&sn=\(account.serial)"
        switch content.kind {
        case .track:
            return [8232, 8224].map { flags in
                ("x-sonos-spotify:\(encoded)?sid=\(sid)&flags=\(flags)&sn=\(account.serial)",
                 meta("00032020\(encoded)", parent: "", content, trackClass, account))
            }
        case .album:
            let real = "1006206c\(encoded)"
            return [("x-rincon-cpcontainer:\(real)?\(query)", meta(real, parent: real, content, playlistClass, account))]
                + ["1004206c", "0004206c"].map { prefix in
                    ("x-rincon-cpcontainer:\(prefix)\(encoded)?\(query)",
                     meta("\(prefix)\(encoded)", parent: "", content, albumClass, account))
                }
        case .playlist:
            let real = "1006206c\(encoded)"
            return [("x-rincon-cpcontainer:\(real)?\(query)", meta(real, parent: real, content, playlistClass, account)),
                    ("x-rincon-cpcontainer:0006206c\(encoded)?\(query)",
                     meta("0006206c\(encoded)", parent: "", content, playlistClass, account))]
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
