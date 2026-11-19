import Foundation
import Observation

/// 音質まわりの RenderingControl アクション
extension SOAPClient {
    private static let instance = ("InstanceID", "0")

    func bass() async throws -> Int {
        let r = try await call(.renderingControl, "GetBass", [Self.instance])
        return Int(r["CurrentBass"] ?? "") ?? 0
    }

    func setBass(_ value: Int) async throws {
        try await call(.renderingControl, "SetBass", [Self.instance, ("DesiredBass", String(value))])
    }

    func treble() async throws -> Int {
        let r = try await call(.renderingControl, "GetTreble", [Self.instance])
        return Int(r["CurrentTreble"] ?? "") ?? 0
    }

    func setTreble(_ value: Int) async throws {
        try await call(.renderingControl, "SetTreble", [Self.instance, ("DesiredTreble", String(value))])
    }

    func loudness() async throws -> Bool {
        let r = try await call(.renderingControl, "GetLoudness", [Self.instance, ("Channel", "Master")])
        return r["CurrentLoudness"] == "1"
    }

    func setLoudness(_ on: Bool) async throws {
        try await call(.renderingControl, "SetLoudness",
                       [Self.instance, ("Channel", "Master"), ("DesiredLoudness", on ? "1" : "0")])
    }

    /// 左右チャンネルの音量（LF / RF、0〜100）。ステレオバランスはこの2つの差で表す
    func channelVolume(_ channel: String) async throws -> Int {
        let r = try await call(.renderingControl, "GetVolume", [Self.instance, ("Channel", channel)])
        return Int(r["CurrentVolume"] ?? "") ?? 100
    }

    func setChannelVolume(_ channel: String, _ value: Int) async throws {
        try await call(.renderingControl, "SetVolume",
                       [Self.instance, ("Channel", channel), ("DesiredVolume", String(value))])
    }

    /// DialogLevel（スピーチエンハンスメント）・NightMode・HeightChannelLevel など
    func eq(_ type: String) async throws -> Int {
        let r = try await call(.renderingControl, "GetEQ", [Self.instance, ("EQType", type)])
        return Int(r["CurrentValue"] ?? "") ?? 0
    }

    func setEQ(_ type: String, _ value: Int) async throws {
        try await call(.renderingControl, "SetEQ", [Self.instance, ("EQType", type), ("DesiredValue", String(value))])
    }
}

/// 1台のスピーカーのサウンド設定。値を変えるとすぐスピーカーに送る（スライダーは最新値だけを順に送る）
@Observable @MainActor
final class SpeakerSound {
    enum LoadState { case loading, loaded, failed }

    let speaker: SonosSpeaker
    private(set) var state: LoadState = .loading

    /// 低音・高音（-10〜+10）
    var bass = 0 { didSet { if bass != oldValue, !loadingValues { bassSender.submit(bass) } } }
    var treble = 0 { didSet { if treble != oldValue, !loadingValues { trebleSender.submit(treble) } } }
    var loudness = false { didSet { if loudness != oldValue { send { try await $0.setLoudness(self.loudness) } } } }

    /// ステレオバランス（-100 = 左のみ、0 = 中央、+100 = 右のみ）。nil は非対応
    var balance: Int? { didSet { if let balance, balance != oldValue, !loadingValues { balanceSender.submit(balance) } } }

    /// スピーチエンハンスメント（サウンドバーなどホームシアター機のみ。nil は非対応）
    var speechEnhancement: Bool? {
        didSet { if let on = speechEnhancement, on != oldValue { send { try await $0.setEQ("DialogLevel", on ? 1 : 0) } } }
    }
    /// ナイトサウンド（ホームシアター機のみ）
    var nightMode: Bool? {
        didSet { if let on = nightMode, on != oldValue { send { try await $0.setEQ("NightMode", on ? 1 : 0) } } }
    }
    /// ハイトオーディオ（Dolby Atmos 対応機のみ。-10〜+10）
    var heightLevel: Int? {
        didSet { if let level = heightLevel, level != oldValue, !loadingValues { heightSender.submit(level) } }
    }

    var isHomeTheater: Bool { speechEnhancement != nil }

    @ObservationIgnored private let client: SOAPClient
    @ObservationIgnored private var bassSender: LatestValueSender!
    @ObservationIgnored private var trebleSender: LatestValueSender!
    @ObservationIgnored private var balanceSender: LatestValueSender!
    @ObservationIgnored private var heightSender: LatestValueSender!
    @ObservationIgnored private var loadingValues = false

    init(speaker: SonosSpeaker) {
        self.speaker = speaker
        client = SOAPClient(host: speaker.host)
        bassSender = sender { try await $0.setBass($1) }
        trebleSender = sender { try await $0.setTreble($1) }
        heightSender = sender { try await $0.setEQ("HeightChannelLevel", $1) }
        balanceSender = sender { client, balance in
            let (left, right) = Self.channels(for: balance)
            try await client.setChannelVolume("LF", left)
            try await client.setChannelVolume("RF", right)
        }
    }

    func load() async {
        loadingValues = true
        defer { loadingValues = false }
        do {
            bass = try await client.bass()
            treble = try await client.treble()
            loudness = try await client.loudness()
        } catch {
            state = .failed
            return
        }
        if let left = try? await client.channelVolume("LF"), let right = try? await client.channelVolume("RF") {
            balance = Self.balance(left: left, right: right)
        } else {
            balance = nil
        }
        // 対応していない機種は 402 を返すので、読めたものだけ表示する
        speechEnhancement = (try? await client.eq("DialogLevel")).map { $0 != 0 }
        nightMode = (try? await client.eq("NightMode")).map { $0 != 0 }
        // HeightChannelLevel は非対応機でも 0 を返すことがあるため、機種で判定する
        if let description = try? await client.deviceDescription(), description.supportsAtmos {
            heightLevel = try? await client.eq("HeightChannelLevel")
        } else {
            heightLevel = nil
        }
        state = .loaded
    }

    /// すべて初期値（Sonos の工場出荷時の値）に戻す
    func reset() {
        bass = 0
        treble = 0
        loudness = true
        if balance != nil { balance = 0 }
        if heightLevel != nil { heightLevel = 0 }
    }

    // MARK: Balance

    /// バランスから左右の音量へ。中央は両方100、右に振るほど左が下がる
    nonisolated static func channels(for balance: Int) -> (left: Int, right: Int) {
        let b = max(-100, min(100, balance))
        return (b > 0 ? 100 - b : 100, b < 0 ? 100 + b : 100)
    }

    nonisolated static func balance(left: Int, right: Int) -> Int {
        max(-100, min(100, right - left))
    }

    // MARK: Sending

    private func send(_ operation: @escaping @MainActor (SOAPClient) async throws -> Void) {
        guard !loadingValues else { return }
        let client = client
        Task {
            do { try await operation(client) } catch { SonosStore.shared.show(error) }
        }
    }

    private func sender(_ operation: @escaping @MainActor (SOAPClient, Int) async throws -> Void) -> LatestValueSender {
        let client = client
        return LatestValueSender { value in
            do { try await operation(client, value) } catch { SonosStore.shared.show(error) }
        }
    }
}
