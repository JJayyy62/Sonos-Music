import Foundation
import Network

/// Bonjour（_sonos._tcp）でスピーカーを探し、IPv4アドレスを通知する。
/// SSDPのマルチキャストは特別なエンタイトルメントが必要なため使わない。
@MainActor
final class SonosDiscovery {
    var onHostFound: ((String) -> Void)?

    private var browser: NWBrowser?
    private var resolved = Set<NWEndpoint>()
    private var connections: [NWEndpoint: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in
                for endpoint in endpoints { self?.resolve(endpoint) }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.stop()
                    try? await Task.sleep(for: .seconds(3))
                    self?.start()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        resolved.removeAll()
    }

    private func resolve(_ endpoint: NWEndpoint) {
        guard !resolved.contains(endpoint), connections[endpoint] == nil else { return }

        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connections[endpoint] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let host = SonosDiscovery.hostString(connection.currentPath?.remoteEndpoint)
                connection.cancel()
                Task { @MainActor in
                    guard let self else { return }
                    self.connections[endpoint] = nil
                    self.resolved.insert(endpoint)
                    if let host { self.onHostFound?(host) }
                }
            case .failed, .waiting:
                connection.cancel()
                Task { @MainActor in self?.connections[endpoint] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.connections[endpoint] != nil {
                connection.cancel()
                self?.connections[endpoint] = nil
            }
        }
    }

    nonisolated static func hostString(_ endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .name(let name, _):
            return name
        case .ipv6:
            return nil
        @unknown default:
            return nil
        }
    }
}
