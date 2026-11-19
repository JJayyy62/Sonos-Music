import Foundation

/// Sonosスピーカー（ポート1400）が公開しているUPnPサービス
struct SonosService: Sendable {
    let controlPath: String
    let type: String

    static let avTransport = SonosService(
        controlPath: "/MediaRenderer/AVTransport/Control",
        type: "urn:schemas-upnp-org:service:AVTransport:1")
    static let renderingControl = SonosService(
        controlPath: "/MediaRenderer/RenderingControl/Control",
        type: "urn:schemas-upnp-org:service:RenderingControl:1")
    static let groupRenderingControl = SonosService(
        controlPath: "/MediaRenderer/GroupRenderingControl/Control",
        type: "urn:schemas-upnp-org:service:GroupRenderingControl:1")
    static let contentDirectory = SonosService(
        controlPath: "/MediaServer/ContentDirectory/Control",
        type: "urn:schemas-upnp-org:service:ContentDirectory:1")
    static let zoneGroupTopology = SonosService(
        controlPath: "/ZoneGroupTopology/Control",
        type: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
    static let deviceProperties = SonosService(
        controlPath: "/DeviceProperties/Control",
        type: "urn:schemas-upnp-org:service:DeviceProperties:1")
}

enum SonosError: LocalizedError {
    case http(Int)
    case upnp(code: Int, action: String)
    case invalidResponse
    case noGroup

    var errorDescription: String? {
        switch self {
        case .http(let status):
            return "スピーカーとの通信に失敗しました（HTTP \(status)）"
        case .upnp(let code, let action):
            return Self.message(for: code, action: action)
        case .invalidResponse:
            return "スピーカーから不正な応答がありました"
        case .noGroup:
            return "スピーカーが選択されていません"
        }
    }

    private static func message(for code: Int, action: String) -> String {
        switch code {
        case 701: return "この操作は現在のソースでは利用できません"
        case 711, 712: return "このソースでは再生モードを変更できません"
        case 714: return "このコンテンツは再生できません"
        case 800: return "Sonosがこの音楽サービスへのアクセスを拒否しました（アカウント設定を確認してください）"
        case 402: return "このスピーカーはその操作に対応していません"
        default: return "操作に失敗しました（\(action) / エラー \(code)）"
        }
    }
}

/// 1台のSonosスピーカーへSOAPリクエストを送る薄いクライアント
struct SOAPClient: Sendable, Hashable {
    let host: String
    var port: Int = 1400

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    var baseURL: String { "http://\(host):\(port)" }

    @discardableResult
    func call(_ service: SonosService, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        guard let url = URL(string: baseURL + service.controlPath) else { throw SonosError.invalidResponse }

        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        body += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        body += "<s:Body><u:\(action) xmlns:u=\"\(service.type)\">"
        for (name, value) in arguments {
            body += "<\(name)>\(XMLEscape.escape(value))</\(name)>"
        }
        body += "</u:\(action)></s:Body></s:Envelope>"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let root = XMLTreeParser.parse(data: data)

        guard status == 200 else {
            if let codeText = root?.firstDescendant("errorCode")?.trimmedText, let code = Int(codeText) {
                throw SonosError.upnp(code: code, action: action)
            }
            throw SonosError.http(status)
        }
        guard let body = root?.firstDescendant("Body"), let responseNode = body.children.first else {
            throw SonosError.invalidResponse
        }
        var values: [String: String] = [:]
        for child in responseNode.children {
            values[child.name] = child.text
        }
        return values
    }

    func get(_ path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw SonosError.invalidResponse }
        let (data, response) = try await Self.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SonosError.http(status) }
        return data
    }
}
