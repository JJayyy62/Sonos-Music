import Foundation

/// Apple Music のカタログIDから、Sonos に渡す URI / メタデータを組み立てる。
/// Sonos 上の Apple Music はサービスID 204（サービスタイプ 52231）。
enum AppleMusicSonos {
    static let serviceType = 52231
    static let serviceID = 204
    static let defaultDesc = "SA_RINCON52231_X_#Svc52231-0-Token"

    enum Content {
        case song(id: String, title: String)
        case album(id: String, title: String)
        case playlist(id: String, title: String)
    }

    /// 再生候補（先頭から順に試す）
    static func candidates(_ content: Content, serial: Int, desc: String?) -> [(uri: String, metadata: String)] {
        let desc = desc ?? defaultDesc
        switch content {
        case let .song(id, title):
            let encoded = "song%3a\(id)"
            return [(
                "x-sonos-http:\(encoded).mp4?sid=\(serviceID)&flags=8224&sn=\(serial)",
                DIDL.metadata(id: "10032020\(encoded)", parentID: "1004206calbum%3a", title: title,
                              upnpClass: "object.item.audioItem.musicTrack", desc: desc, isContainer: false)
            )]
        case let .album(id, title):
            return ["1004206c", "0004206c"].map { (flags) -> (uri: String, metadata: String) in
                let objectID = "\(flags)album%3a\(id)"
                return ("x-rincon-cpcontainer:\(objectID)",
                        DIDL.metadata(id: objectID, parentID: "00020000album%3a", title: title,
                                      upnpClass: "object.container.album.musicAlbum", desc: desc, isContainer: false))
            }
        case let .playlist(id, title):
            let objectID = "1006206cplaylist%3a\(id)"
            return [(
                "x-rincon-cpcontainer:\(objectID)",
                DIDL.metadata(id: objectID, parentID: "00020000playlist%3a", title: title,
                              upnpClass: "object.container.playlistContainer", desc: desc, isContainer: false)
            )]
        }
    }

    /// Sonosで再生中のURIから Apple Music の曲IDを取り出す
    static func catalogSongID(in uri: String) -> String? {
        guard uri.contains("sid=\(serviceID)") else { return nil }
        return uri.firstMatch(#"song(?:%3a|:)(\d+)"#)
    }

    /// URIやメタデータに含まれるアカウント番号（sn=）
    static func serial(in text: String) -> Int? {
        text.firstMatch(#"sid=204[^\s"<]*?sn=(\d+)"#).flatMap { Int($0) }
    }

    static func desc(in text: String) -> String? {
        text.firstMatch(#"(SA_RINCON52231_[^<"\s]*)"#)
    }

    /// Sonos が扱えるカタログIDか（ライブラリIDの "l." "p." "i." は不可）
    static func isCatalogAlbumID(_ id: String) -> Bool { id.allSatisfy(\.isNumber) }
    static func isCatalogPlaylistID(_ id: String) -> Bool { id.hasPrefix("pl.") }
}
