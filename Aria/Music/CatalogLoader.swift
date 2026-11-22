import Foundation

/// サービスごとの「アルバム／プレイリストの曲一覧」「アーティストの曲・アルバム」の取得先を振り分ける
@MainActor
enum CatalogLoader {
    static func tracks(of collection: CatalogCollection) async throws -> [CatalogTrack] {
        switch collection.service {
        case .spotify:
            return try await SpotifyService.shared.tracks(of: collection)
        case .appleMusic:
            switch collection.kind {
            case .album: return try await ITunesCatalog.albumTracks(collection.serviceID)
            case .playlist where collection.serviceID.hasPrefix("p."):
                return try await AppleMusicService.shared.libraryPlaylistTracks(collection.serviceID)
            default: return []
            }
        }
    }

    static func artistAlbums(_ artist: CatalogArtist) async throws -> [CatalogCollection] {
        switch artist.service {
        case .spotify: return try await SpotifyService.shared.artistAlbums(artist)
        case .appleMusic: return try await ITunesCatalog.artistAlbums(artist.serviceID)
        }
    }

    static func artistTopTracks(_ artist: CatalogArtist) async -> [CatalogTrack] {
        switch artist.service {
        case .spotify: return await SpotifyService.shared.artistTopTracks(artist)
        case .appleMusic: return await ITunesCatalog.artistSongs(artist.serviceID)
        }
    }
}
