import Foundation

/// Sonos の新しいローカル API（https://<スピーカー>:1443/api/v1）。純正 Sonos アプリが使っているもので、
/// UPnP では分からない「いま再生している音源の品質」（ビット深度・サンプルレート・ロスレス・空間オーディオ）が取れる。
///
/// スピーカーは自己署名証明書を使うので、接続先がそのスピーカー自身（ローカルネットワークのアドレス）のときだけ証明書を受け入れる。
actor SonosLocalAPI {
    static let shared = SonosLocalAPI()

    /// Sonos がローカル連携向けに公開している API キー
    private static let apiKey = "123e4567-e89b-12d3-a456-426655440000"

    struct TrackQuality: Equatable, Sendable {
        var bitDepth: Int?
        var sampleRate: Int?
        var lossless: Bool?
        var immersive: Bool?
        var codec: String?

        var isEmpty: Bool { bitDepth == nil && sampleRate == nil && lossless == nil && immersive == nil && codec == nil }
    }

    struct CurrentTrack: Sendable {
        var name: String?
        var artist: String?
        var album: String?
        var durationMillis: Int?
        var quality: TrackQuality?
    }

    private let session: URLSession
    /// スピーカーごとのグループID（"RINCON_xxx:数字"）。グループを組み替えると変わる
    private var groupIDs: [String: String] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        session = URLSession(configuration: configuration, delegate: LocalSpeakerTrust(), delegateQueue: nil)
    }

    /// コーディネーターのスピーカーで再生中の曲
    func currentTrack(host: String) async -> CurrentTrack? {
        guard let groupID = await groupID(host: host) else { return nil }
        guard let json = await get(host: host, path: "groups/\(groupID)/playbackMetadata") else {
            // グループが組み替わっていたら、次回は取り直す
            groupIDs[host] = nil
            return nil
        }
        guard let item = json["currentItem"] as? [String: Any],
              let track = item["track"] as? [String: Any] else { return nil }
        var result = CurrentTrack()
        result.name = track["name"] as? String
        result.artist = (track["artist"] as? [String: Any])?["name"] as? String
        result.album = (track["album"] as? [String: Any])?["name"] as? String
        result.durationMillis = track["durationMillis"] as? Int
        if let quality = track["quality"] as? [String: Any] {
            let parsed = TrackQuality(
                bitDepth: quality["bitDepth"] as? Int,
                sampleRate: quality["sampleRate"] as? Int,
                lossless: quality["lossless"] as? Bool,
                immersive: quality["immersive"] as? Bool,
                codec: quality["codec"] as? String)
            result.quality = parsed.isEmpty ? nil : parsed
        }
        return result
    }

    private func groupID(host: String) async -> String? {
        if let cached = groupIDs[host] { return cached }
        guard let info = await get(host: host, path: "players/local/info"),
              let groupID = info["groupId"] as? String else { return nil }
        groupIDs[host] = groupID
        return groupID
    }

    private func get(host: String, path: String) async -> [String: Any]? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://\(host):1443/api/v1/\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// スピーカーの自己署名証明書を、ローカルネットワークのアドレスに対してだけ受け入れる
private final class LocalSpeakerTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.port == 1443, Self.isLocalAddress(space.host),
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// 10.x / 172.16-31.x / 192.168.x / 169.254.x（リンクローカル）だけ
    static func isLocalAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
