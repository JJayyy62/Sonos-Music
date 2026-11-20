import Foundation

/// Better Lyrics API（https://docs.betterlyrics.org）
///
/// - `GET https://api.betterlyrics.org/getLyrics?s=曲名&a=アーティスト&al=アルバム&d=秒`
/// - 200: `{"ttml": "...", "score": 0.97}`（単語・音節単位またはTTMLの行単位）
/// - 404: 歌詞なし（キャッシュされる）
/// - 401: キャッシュに無く、APIキーが必要（キーは第三者に配布されていないので、この場合は他の取得元へ）
/// - 429 / 5xx: 混雑・障害
enum BetterLyricsClient {
    enum Outcome {
        case found([LyricLine])
        case notFound
        case unavailable
    }

    private struct Response: Decodable {
        let ttml: String
    }

    private static let endpoint = "https://api.betterlyrics.org/getLyrics"

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Outcome {
        guard var components = URLComponents(string: endpoint) else { return .unavailable }
        var items = [URLQueryItem(name: "s", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "a", value: artist)) }
        if !album.isEmpty { items.append(URLQueryItem(name: "al", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "d", value: String(Int(duration.rounded())))) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return .unavailable }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aria/1.0 (Sonos music player for iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                let body = try JSONDecoder().decode(Response.self, from: data)
                let lines = TTMLParser.parse(body.ttml)
                return lines.contains { !$0.isInterlude } ? .found(lines) : .notFound
            case 404:
                return .notFound
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}
