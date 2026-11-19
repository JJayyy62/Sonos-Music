import Foundation

/// 再生中の音源品質（ロスレス / Dolby Atmos など）
struct AudioQuality: Equatable, Sendable {
    enum Badge: Sendable {
        case dolbyAtmos, hiResLossless, lossless, dolbyAudio, surround

        var symbol: String {
            switch self {
            case .dolbyAtmos: return "dot.radiowaves.left.and.right"
            case .hiResLossless, .lossless: return "waveform"
            case .dolbyAudio: return "speaker.wave.2.fill"
            case .surround: return "hifispeaker.2.fill"
            }
        }
    }

    enum Source: Sendable {
        case stream, homeTheater, appleMusicCatalog

        var label: String {
            switch self {
            case .stream: return "Sonosが受信しているストリーム情報"
            case .homeTheater: return "サウンドバーのHDMI / 光入力情報"
            case .appleMusicCatalog: return "Apple Musicのカタログ情報"
            }
        }
    }

    var badge: Badge?
    var title: String
    var formatDetail: String?
    var source: Source
    var notes: [String] = []
}

enum AudioQualityDetector {
    private static let losslessMimes = ["flac", "x-flac", "alac", "x-alac", "wav", "x-wav", "wave", "aiff", "x-aiff", "l16", "l24", "dsd"]
    private static let losslessExtensions = ["flac", "alac", "wav", "aif", "aiff", "dsf", "dff"]

    // MARK: Sonos stream metadata

    static func fromStream(_ track: TrackInfo) -> AudioQuality? {
        let mime = mimeType(track.protocolInfo)
        let ext = fileExtension(track.uri)
        let bits = Int(track.resAttributes["bitsPerSample"] ?? "")
        let rate = Int(track.resAttributes["sampleFrequency"] ?? "")
        let channels = Int(track.resAttributes["nrAudioChannels"] ?? "")
        let codec = codecName(mime: mime, ext: ext)
        let detail = formatDetail(codec: codec, bits: bits, rate: rate, channels: channels)

        let uriHay = (track.uri + " " + (track.protocolInfo ?? "")).lowercased()
        let metaHay = track.rawMetadata.lowercased()
        if uriHay.contains("atmos") || uriHay.contains("ac-4") || uriHay.contains("/ac4") || metaHay.contains("dolby atmos") {
            return AudioQuality(badge: .dolbyAtmos, title: "Dolby Atmos", formatDetail: detail, source: .stream)
        }

        let lossless = losslessMimes.contains { mime == $0 || mime.hasSuffix("/\($0)") } || losslessExtensions.contains(ext)
        if lossless {
            let hiRes = (bits ?? 16) > 16 || (rate ?? 44_100) > 48_000
            return AudioQuality(badge: hiRes ? .hiResLossless : .lossless,
                                title: hiRes ? "ハイレゾロスレス" : "ロスレス",
                                formatDetail: detail, source: .stream)
        }
        if mime.contains("eac3") || mime.contains("ec-3") || mime.contains("ac3") {
            return AudioQuality(badge: .dolbyAudio, title: "Dolby Digital", formatDetail: detail, source: .stream)
        }
        if let channels, channels > 2 {
            return AudioQuality(badge: .surround, title: "\(channels)ch", formatDetail: detail, source: .stream)
        }
        guard codec != nil else { return nil }
        return AudioQuality(badge: nil, title: codec ?? "標準音質", formatDetail: detail, source: .stream)
    }

    // MARK: Home theater (HTAudioIn)

    private static let homeTheaterFormats: [Int: String] = [
        2: "ステレオ PCM",
        7: "Dolby 2.0",
        18: "Dolby 5.1",
        59: "Dolby Atmos（DD+）",
        61: "Dolby Atmos（TrueHD）",
        63: "Dolby Atmos",
        33_554_434: "PCM 2.0",
        33_554_488: "Dolby 2.0",
        33_554_490: "Dolby Digital Plus 2.0",
        33_554_492: "Dolby TrueHD 2.0",
        33_554_494: "Dolby マルチチャンネル PCM 2.0",
        84_934_658: "マルチチャンネル PCM 5.1",
        84_934_713: "Dolby 5.1",
        84_934_714: "Dolby Digital Plus 5.1",
        84_934_716: "Dolby TrueHD 5.1",
        84_934_718: "Dolby マルチチャンネル PCM 5.1",
        84_934_721: "DTS 5.1",
        118_489_090: "マルチチャンネル PCM 7.1",
        118_489_146: "Dolby Digital Plus 7.1",
        118_489_148: "Dolby TrueHD 7.1",
        118_489_150: "Dolby マルチチャンネル PCM 7.1",
        402_653_242: "Dolby Atmos（DD+）",
        402_653_244: "Dolby Atmos（TrueHD）",
        402_653_246: "Dolby Atmos（マルチチャンネル PCM）",
    ]

    static func fromHomeTheater(code: Int) -> AudioQuality? {
        guard code != 0, code != 21, code != 22 else { return nil } // 入力なし / 無音
        guard let name = homeTheaterFormats[code] else {
            return AudioQuality(badge: nil, title: "テレビ音声", formatDetail: "フォーマットコード \(code)", source: .homeTheater)
        }
        let badge: AudioQuality.Badge?
        if name.contains("Atmos") { badge = .dolbyAtmos }
        else if name.contains("Dolby") || name.contains("DTS") { badge = .dolbyAudio }
        else if name.contains("5.1") || name.contains("7.1") { badge = .surround }
        else { badge = nil }
        return AudioQuality(badge: badge, title: badge == .dolbyAtmos ? "Dolby Atmos" : name,
                            formatDetail: name, source: .homeTheater)
    }

    // MARK: Apple Music catalog

    static func fromAppleMusic(traits: [String], speakerSupportsAtmos: Bool) -> AudioQuality? {
        let set = Set(traits.map { $0.lowercased() })
        guard !set.isEmpty else { return nil }
        let atmos = set.contains("atmos") || set.contains("dolby-atmos")
        let hiRes = set.contains("hi-res-lossless")
        let lossless = hiRes || set.contains("lossless")

        var notes = ["Apple Musicのカタログに登録されている、この曲の対応フォーマットに基づく表示です。Sonosが実際に受信している形式とは異なる場合があります。"]

        if atmos && speakerSupportsAtmos {
            return AudioQuality(badge: .dolbyAtmos, title: "Dolby Atmos", formatDetail: "空間オーディオ（Dolby Atmos）",
                                source: .appleMusicCatalog, notes: notes)
        }
        if atmos {
            notes.append("この曲はDolby Atmosに対応していますが、再生中のスピーカーはDolby Atmos非対応のためステレオで再生されます。")
        }
        if lossless {
            if hiRes {
                notes.append("Sonosの再生は最大24ビット/48kHzのため、ハイレゾ音源は48kHz以下で再生されます。")
            }
            return AudioQuality(badge: .lossless, title: "ロスレス",
                                formatDetail: hiRes ? "ALAC（音源は最大24ビット/192kHz）" : "ALAC（最大24ビット/48kHz）",
                                source: .appleMusicCatalog, notes: notes)
        }
        return AudioQuality(badge: nil, title: "AAC", formatDetail: "AAC 256kbps", source: .appleMusicCatalog, notes: notes)
    }

    // MARK: Helpers

    private static func mimeType(_ protocolInfo: String?) -> String {
        guard let parts = protocolInfo?.split(separator: ":", omittingEmptySubsequences: false), parts.count >= 3 else { return "" }
        return parts[2].lowercased()
    }

    private static func fileExtension(_ uri: String) -> String {
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        guard let dot = path.lastIndex(of: "."), path.distance(from: dot, to: path.endIndex) <= 6 else { return "" }
        return path[path.index(after: dot)...].lowercased()
    }

    private static func codecName(mime: String, ext: String) -> String? {
        let key = mime.isEmpty ? ext : mime
        if key.contains("flac") { return "FLAC" }
        if key.contains("alac") { return "ALAC" }
        if key.contains("wav") { return "WAV" }
        if key.contains("aif") { return "AIFF" }
        if key.contains("eac3") || key.contains("ec-3") { return "Dolby Digital Plus" }
        if key.contains("ac3") { return "Dolby Digital" }
        if key.contains("mpeg") || key.contains("mp3") { return "MP3" }
        if key.contains("aac") || key.contains("mp4") || key.contains("m4a") { return "AAC" }
        if key.contains("ogg") || key.contains("vorbis") { return "Ogg Vorbis" }
        if key.contains("opus") { return "Opus" }
        if key.contains("wma") { return "WMA" }
        return nil
    }

    private static func formatDetail(codec: String?, bits: Int?, rate: Int?, channels: Int?) -> String? {
        var parts: [String] = []
        if let codec { parts.append(codec) }
        if let bits { parts.append("\(bits)ビット") }
        if let rate {
            let khz = Double(rate) / 1000
            parts.append(khz == khz.rounded() ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz))
        }
        if let channels, channels > 2 { parts.append("\(channels)ch") }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}
