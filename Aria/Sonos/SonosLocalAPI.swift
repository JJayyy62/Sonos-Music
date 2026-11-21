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
        /// 再生元の種類（"playlist"、Spotify Connect なら "spotify.connect" や "album.spotify.connect" など）
        var containerType: String?
        var containerName: String?
        /// 次に流れる曲（Spotify Connect では Spotify が決める）
        var nextName: String?
        var nextArtist: String?
        var nextImageURL: URL?

        /// Spotify が次の曲を決める再生か（Sonos のキューは使われない）
        var isSpotifyConnect: Bool { containerType?.contains("spotify") == true }
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
        if let container = json["container"] as? [String: Any] {
            result.containerType = container["type"] as? String
            result.containerName = container["name"] as? String
        }
        if let next = (json["nextItem"] as? [String: Any])?["track"] as? [String: Any] {
            result.nextName = next["name"] as? String
            result.nextArtist = (next["artist"] as? [String: Any])?["name"] as? String
            result.nextImageURL = (next["imageUrl"] as? String).flatMap(URL.init(string:))
        }
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

    enum LoadError: LocalizedError {
        case noGroup
        case rejected(Int, String?)

        var errorDescription: String? {
            switch self {
            case .noGroup: return "スピーカーのグループを確認できませんでした"
            case .rejected(_, let reason):
                return "Sonosが再生を受け付けませんでした" + (reason.map { "（\($0)）" } ?? "")
            }
        }
    }

    /// 曲・アルバム・プレイリストを再生する（純正 Sonos アプリと同じ API。キューは置き換わる）。
    /// UPnP では Sonos が Spotify の追加を拒否するため、Spotify はこちらで再生する
    func loadContent(host: String, type: String, serviceID: Int, objectID: String, accountSerial: Int) async throws {
        guard let groupID = await groupID(host: host) else { throw LoadError.noGroup }
        let body: [String: Any] = [
            "type": type,
            "id": ["serviceId": String(serviceID), "objectId": objectID, "accountId": "sn_\(accountSerial)"],
            "playbackAction": "PLAY",
        ]
        let (status, data) = await post(host: host, path: "groups/\(groupID)/playback/content", body: body)
        if status == 200 { return }
        // グループが組み替わっていたら取り直して、もう一度だけ試す
        groupIDs[host] = nil
        if let retried = await self.groupID(host: host), retried != groupID {
            let (again, _) = await post(host: host, path: "groups/\(retried)/playback/content", body: body)
            if again == 200 { return }
        }
        let reason = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["errorCode"] as? String
        throw LoadError.rejected(status, reason)
    }

    private func post(host: String, path: String, body: [String: Any]) async -> (Int, Data?) {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://\(host):1443/api/v1/\(encoded)") else { return (0, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request) else { return (0, nil) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
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
