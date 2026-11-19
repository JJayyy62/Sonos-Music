import Foundation

struct SonosSpeaker: Identifiable, Hashable, Sendable {
    let uuid: String
    let roomName: String
    let host: String
    var id: String { uuid }
}

struct SonosGroup: Identifiable, Hashable, Sendable {
    let id: String
    let coordinator: SonosSpeaker
    let members: [SonosSpeaker]

    var name: String {
        members.count <= 1 ? coordinator.roomName : "\(coordinator.roomName) + \(members.count - 1)"
    }

    var fullName: String { members.map(\.roomName).joined(separator: "、") }

    func contains(_ uuid: String) -> Bool {
        coordinator.uuid == uuid || members.contains { $0.uuid == uuid }
    }
}

enum TransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
}

enum RepeatMode: Sendable {
    case off, all, one
}

struct PlayMode: Equatable, Sendable {
    var shuffle = false
    var repeatMode: RepeatMode = .off

    init(shuffle: Bool = false, repeatMode: RepeatMode = .off) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }

    init(sonos value: String) {
        switch value {
        case "REPEAT_ALL": self.init(shuffle: false, repeatMode: .all)
        case "REPEAT_ONE": self.init(shuffle: false, repeatMode: .one)
        case "SHUFFLE_NOREPEAT": self.init(shuffle: true, repeatMode: .off)
        case "SHUFFLE": self.init(shuffle: true, repeatMode: .all)
        case "SHUFFLE_REPEAT_ONE": self.init(shuffle: true, repeatMode: .one)
        default: self.init()
        }
    }

    var sonosValue: String {
        switch (shuffle, repeatMode) {
        case (false, .off): return "NORMAL"
        case (false, .all): return "REPEAT_ALL"
        case (false, .one): return "REPEAT_ONE"
        case (true, .off): return "SHUFFLE_NOREPEAT"
        case (true, .all): return "SHUFFLE"
        case (true, .one): return "SHUFFLE_REPEAT_ONE"
        }
    }
}

struct PositionInfo: Sendable {
    var trackNumber: Int
    var duration: Double
    var position: Double
    var uri: String
    var metadata: String
}

struct MediaInfo: Equatable, Sendable {
    var currentURI: String
    var currentURIMetaData: String
    var numberOfTracks: Int
}

struct BrowseResult: Sendable {
    var items: [DIDLItem]
    var total: Int
}

struct DeviceDescription: Sendable {
    var modelName: String
    var modelNumber: String
    var displayName: String

    /// Dolby Atmos を再生できるモデルか（Arc / Arc Ultra / Era 300 / Beam 第2世代）
    var supportsAtmos: Bool {
        let name = (modelName + " " + displayName).lowercased()
        if name.contains("arc") || name.contains("era 300") { return true }
        if name.contains("beam") { return modelNumber.uppercased() != "S14" } // S14 = Beam 第1世代
        return false
    }
}

struct SonosAccount: Sendable {
    var type: Int
    var serial: Int
}

/// 再生中トラックの表示用モデル
struct TrackInfo: Equatable, Sendable {
    enum Kind: Sendable { case track, radio, tv, lineIn }

    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var uri: String
    var duration: Double
    var trackNumber: Int
    var kind: Kind
    var stationName: String?
    var protocolInfo: String?
    var resAttributes: [String: String]
    var rawMetadata: String

    var identity: String { "\(uri)|\(title)|\(artist)" }
    var isLive: Bool { kind != .track || duration <= 0 }

    static func make(position: PositionInfo, media: MediaInfo?, host: String) -> TrackInfo? {
        let item = DIDL.parse(position.metadata).first
        let uri = position.uri.isEmpty ? (media?.currentURI ?? "") : position.uri
        if uri.isEmpty && item == nil { return nil }
        let mediaItem = DIDL.parse(media?.currentURIMetaData ?? "").first

        var kind: Kind = .track
        if uri.hasPrefix("x-sonos-htastream:") {
            kind = .tv
        } else if uri.hasPrefix("x-rincon-stream:") {
            kind = .lineIn
        } else if position.duration <= 0,
                  SonosStore.isStreamURI(uri) || SonosStore.isStreamURI(media?.currentURI ?? "") || item?.streamContent != nil {
            kind = .radio
        }

        var title = item?.title ?? ""
        var artist = item?.artist ?? ""
        var album = item?.album ?? ""
        var stationName: String?

        switch kind {
        case .radio:
            stationName = mediaItem?.title.nilIfEmpty
            if let content = item?.streamContent, let parsed = StreamTitle.parse(content) {
                title = parsed.title
                artist = parsed.artist ?? stationName ?? artist
                if let parsedAlbum = parsed.album { album = parsedAlbum }
            } else if title.isEmpty || title.hasPrefix("x-") {
                title = stationName ?? "ラジオ"
            }
            if artist.isEmpty, let stationName, stationName != title { artist = stationName }
        case .tv:
            title = "テレビ"
            artist = ""
        case .lineIn:
            if title.isEmpty { title = "ライン入力" }
        case .track:
            break
        }

        let art = item?.albumArtURI ?? mediaItem?.albumArtURI
        let duration = position.duration > 0 ? position.duration : (item?.durationSeconds ?? 0)
        return TrackInfo(
            title: title, artist: artist, album: album,
            artworkURL: DIDLItem.resolveArtwork(art, host: host),
            uri: uri, duration: duration, trackNumber: position.trackNumber, kind: kind,
            stationName: stationName, protocolInfo: item?.protocolInfo,
            resAttributes: item?.resAttributes ?? [:], rawMetadata: position.metadata)
    }
}
