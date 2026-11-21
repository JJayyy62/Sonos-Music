import Foundation

/// サービスをまたいで使う、棚や検索結果のアルバム／プレイリスト
struct CatalogCollection: Identifiable, Hashable, Sendable {
    var service: StreamingService
    var kind: ServiceContent.Kind
    var serviceID: String
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var detail: String?

    var id: String { "\(service.rawValue)-\(kind.rawValue)-\(serviceID)" }
    var content: ServiceContent { ServiceContent(service: service, kind: kind, id: serviceID, title: title) }
}

/// サービスをまたいで使う曲
struct CatalogTrack: Identifiable, Hashable, Sendable {
    var service: StreamingService
    var serviceID: String
    var title: String
    var artist: String
    var album: String?
    var albumID: String?
    var artworkURL: URL?
    var duration: Double?
    var number: Int?
    /// Explicit（E マーク）の曲
    var explicit = false

    var id: String { "\(service.rawValue)-\(serviceID)" }
    var content: ServiceContent { .song(service, id: serviceID, title: title, albumID: albumID) }
}

struct CatalogArtist: Identifiable, Hashable, Sendable {
    var service: StreamingService
    var serviceID: String
    var name: String
    var artworkURL: URL?

    var id: String { "\(service.rawValue)-\(serviceID)" }
}

struct CatalogShelf: Identifiable, Sendable {
    var id: String { "\(service.rawValue)-\(title)" }
    var service: StreamingService
    var title: String
    var items: [CatalogCollection]
}

struct CatalogSearchResults: Sendable {
    var tracks: [CatalogTrack] = []
    var albums: [CatalogCollection] = []
    var playlists: [CatalogCollection] = []
    var artists: [CatalogArtist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty }
}
