import Foundation

/// Apple Music（Sonos のサービスID 204）固有の補助。URI の組み立ては SonosServiceURI に共通化している
enum AppleMusicSonos {
    enum Content {
        case song(id: String, title: String)
        case album(id: String, title: String)
        case playlist(id: String, title: String)

        var serviceContent: ServiceContent {
            switch self {
            case let .song(id, title): return .song(.appleMusic, id: id, title: title)
            case let .album(id, title): return .album(.appleMusic, id: id, title: title)
            case let .playlist(id, title): return .playlist(.appleMusic, id: id, title: title)
            }
        }
    }

    /// Sonosで再生中のURIから Apple Music の曲IDを取り出す
    static func catalogSongID(in uri: String) -> String? {
        guard uri.contains("sid=\(StreamingService.appleMusic.sonosServiceID)") else { return nil }
        return uri.firstMatch(#"song(?:%3a|:)(\d+)"#)
    }

    /// Sonos が扱えるアルバムIDか（ライブラリのアルバム "l." は不可）
    static func isCatalogAlbumID(_ id: String) -> Bool { id.allSatisfy(\.isNumber) }
    /// カタログのプレイリスト（pl.）と、自分のライブラリのプレイリスト（p.）は再生できる
    static func isCatalogPlaylistID(_ id: String) -> Bool { id.hasPrefix("pl.") || id.hasPrefix("p.") }
}
