import Foundation

/// DIDL-Lite の item / container 1件分
struct DIDLItem: Identifiable, Hashable, Sendable {
    var id: String
    var parentID = ""
    var isContainer = false
    var title = ""
    var creator: String?
    var album: String?
    var albumArtist: String?
    var albumArtURI: String?
    var upnpClass = ""
    var resURI: String?
    var protocolInfo: String?
    var duration: String?
    var resAttributes: [String: String] = [:]
    /// お気に入り（FV:2）が内部に持つ元アイテムのメタデータ
    var resMD: String?
    var streamContent: String?
    var desc: String?
    /// お気に入りの「Apple Music アルバム」などの説明
    var serviceDescription: String?
    var trackNumber: Int?

    var artist: String? { creator ?? albumArtist }
    var durationSeconds: Double? { duration.flatMap(TimeFormat.parse) }
    var isFavorite: Bool { id.hasPrefix("FV:") }

    /// 中身をブラウズできるコンテナか（お気に入りはブラウズ不可）
    var isBrowsable: Bool { isContainer && !isFavorite }

    var isAlbumLike: Bool {
        upnpClass.contains("album") || upnpClass.contains("playlist")
    }

    func artworkURL(host: String?) -> URL? {
        Self.resolveArtwork(albumArtURI ?? favoriteArtwork, host: host)
    }

    /// お気に入りは resMD 内にアートワークを持っていることがある
    private var favoriteArtwork: String? {
        guard let resMD, let inner = DIDL.parse(resMD).first else { return nil }
        return inner.albumArtURI
    }

    static func resolveArtwork(_ uri: String?, host: String?) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return URL(string: uri)
        }
        guard let host else { return nil }
        let path = uri.hasPrefix("/") ? uri : "/" + uri
        return URL(string: "http://\(host):1400\(path)")
    }
}

enum DIDL {
    static let header = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"

    static func parse(_ xml: String) -> [DIDLItem] {
        guard !xml.isEmpty, xml != "NOT_IMPLEMENTED", let root = XMLTreeParser.parse(string: xml) else { return [] }
        let nodes = root.children.filter { $0.name == "item" || $0.name == "container" }
        return nodes.map(item(from:))
    }

    private static func item(from node: XMLElementNode) -> DIDLItem {
        var item = DIDLItem(id: node.attributes["id"] ?? UUID().uuidString)
        item.parentID = node.attributes["parentID"] ?? ""
        item.isContainer = node.name == "container"
        for child in node.children {
            let text = child.trimmedText
            switch child.name {
            case "title": item.title = text
            case "creator": item.creator = text.nilIfEmpty
            case "artist": if item.creator == nil { item.creator = text.nilIfEmpty }
            case "album": item.album = text.nilIfEmpty
            case "albumArtist": item.albumArtist = text.nilIfEmpty
            case "albumArtURI": if item.albumArtURI == nil { item.albumArtURI = text.nilIfEmpty }
            case "class": item.upnpClass = text
            case "res":
                if item.resURI == nil {
                    item.resURI = text.nilIfEmpty
                    item.protocolInfo = child.attributes["protocolInfo"]
                    item.duration = child.attributes["duration"]
                    item.resAttributes = child.attributes
                }
            case "resMD": item.resMD = text.nilIfEmpty
            case "streamContent": item.streamContent = text.nilIfEmpty
            case "desc": item.desc = text.nilIfEmpty
            case "description": item.serviceDescription = text.nilIfEmpty
            case "originalTrackNumber": item.trackNumber = Int(text)
            default: break
            }
        }
        return item
    }

    static func metadata(id: String, parentID: String, title: String, upnpClass: String,
                         desc: String = "RINCON_AssociatedZPUDN", isContainer: Bool) -> String {
        let tag = isContainer ? "container" : "item"
        let e = XMLEscape.escape
        return header
            + "<\(tag) id=\"\(e(id))\" parentID=\"\(e(parentID))\" restricted=\"true\">"
            + "<dc:title>\(e(title))</dc:title>"
            + "<upnp:class>\(e(upnpClass))</upnp:class>"
            + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(e(desc))</desc>"
            + "</\(tag)></DIDL-Lite>"
    }

    /// キュー追加などで送るメタデータ
    static func metadata(for item: DIDLItem) -> String {
        if let resMD = item.resMD, !resMD.isEmpty { return resMD }
        return metadata(id: item.id, parentID: item.parentID, title: item.title, upnpClass: item.upnpClass,
                        desc: item.desc ?? "RINCON_AssociatedZPUDN", isContainer: item.isContainer)
    }
}

/// ラジオ局の r:streamContent（"TYPE=SNG|TITLE ...|ARTIST ..." や "アーティスト - 曲名"）
struct StreamTitle {
    var title: String
    var artist: String?
    var album: String?

    static func parse(_ raw: String) -> StreamTitle? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("ZPSTR_") { return nil }
        if s.contains("|") && (s.hasPrefix("TYPE=") || s.contains("TITLE ")) {
            var result = StreamTitle(title: "")
            for part in s.split(separator: "|").map(String.init) {
                if part.hasPrefix("TITLE ") { result.title = String(part.dropFirst(6)) }
                else if part.hasPrefix("ARTIST ") { result.artist = String(part.dropFirst(7)).nilIfEmpty }
                else if part.hasPrefix("ALBUM ") { result.album = String(part.dropFirst(6)).nilIfEmpty }
            }
            return result.title.isEmpty ? nil : result
        }
        if let range = s.range(of: " - ") {
            return StreamTitle(title: String(s[range.upperBound...]), artist: String(s[..<range.lowerBound]))
        }
        return StreamTitle(title: s)
    }
}
