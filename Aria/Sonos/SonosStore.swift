import Foundation
import Observation
import SwiftUI

/// 最新値だけを順番に送る（音量ドラッグ・回転ジェスチャー用）
@MainActor
final class LatestValueSender {
    private var pending: Int?
    private var sending = false
    private let send: @MainActor (Int) async throws -> Void

    init(_ send: @escaping @MainActor (Int) async throws -> Void) {
        self.send = send
    }

    func submit(_ value: Int) {
        pending = value
        guard !sending else { return }
        sending = true
        Task {
            while let value = self.pending {
                self.pending = nil
                try? await self.send(value)
            }
            self.sending = false
        }
    }
}

enum EnqueueMode {
    case next, end
}

@Observable @MainActor
final class SonosStore {
    static let shared = SonosStore()

    enum ConnectionState: Equatable {
        case searching, connected, unreachable
    }

    private enum Keys {
        static let selected = "selectedCoordinator"
        static let hosts = "knownHosts"
        /// 旧バージョンの Apple Music 用キー（そのまま Apple Music の手動指定として使う）
        static let serialOverride = "appleMusicSerialOverride"
        static func serialOverride(_ service: StreamingService) -> String {
            service == .appleMusic ? serialOverride : "serialOverride.\(service.rawValue)"
        }
    }

    // MARK: Topology

    private(set) var groups: [SonosGroup] = []
    private(set) var connection: ConnectionState = .searching
    private(set) var selectedCoordinatorID: String? = UserDefaults.standard.string(forKey: Keys.selected)
    private(set) var knownHosts: [String] = UserDefaults.standard.stringArray(forKey: Keys.hosts) ?? []

    var selectedGroup: SonosGroup? {
        guard !groups.isEmpty else { return nil }
        if let id = selectedCoordinatorID {
            if let group = groups.first(where: { $0.coordinator.uuid == id }) { return group }
            if let group = groups.first(where: { $0.contains(id) }) { return group }
        }
        return groups.first
    }

    var allSpeakers: [SonosSpeaker] {
        groups.flatMap(\.members).sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
    }

    var artworkHost: String? { selectedGroup?.coordinator.host }

    // MARK: Playback state

    private(set) var track: TrackInfo?
    private(set) var transportState: TransportState = .stopped
    private(set) var playMode = PlayMode()
    private(set) var groupVolume = 0
    private(set) var groupMuted = false
    private(set) var memberVolumes: [String: Int] = [:]
    private(set) var queue: [DIDLItem] = []
    private(set) var currentTrackNumber = 0
    private(set) var mediaInfo: MediaInfo?
    private(set) var quality: AudioQuality?
    /// 再生中の曲の、端末の言語での表記（Sonos がローマ字で返す日本の曲名など）。なければ nil
    private(set) var trackNames: TrackNames?
    private(set) var favorites: [DIDLItem] = []
    private(set) var sleepTimerRemaining: Int?
    private(set) var crossfade = false
    /// サービスごとに自動検出した Sonos のアカウント番号
    private(set) var detectedSerials: [StreamingService: Int] = [:]
    /// Sonos に登録されていると分かったサービス（アカウント一覧・お気に入り・キューから推定）
    private(set) var linkedServices: Set<StreamingService> = []
    private(set) var toast: String?
    let lyrics = LyricsStore()

    private var positionSeconds: Double = 0
    private var positionDate = Date()

    var isPlaying: Bool { transportState == .playing || transportState == .transitioning }
    var isPlayingQueue: Bool { mediaInfo?.currentURI.hasPrefix("x-rincon-queue:") ?? false }
    var duration: Double { track?.duration ?? 0 }

    /// 画面に出す曲名・アーティスト名・アルバム名（日本語表記が見つかればそれを使う）
    var displayTitle: String? { trackNames?.title ?? track?.title }
    var displayArtist: String? { trackNames?.artist ?? track?.artist }
    var displayAlbum: String? { trackNames?.album ?? track?.album }

    /// 再生位置（ポーリングの間はローカルで補間する）
    func position(at date: Date = Date()) -> Double {
        var value = positionSeconds
        if transportState == .playing { value += date.timeIntervalSince(positionDate) }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    /// サービスの再生に使うアカウント（手動指定 → 自動検出 → 既定値の順）
    func account(for service: StreamingService) -> ServiceAccount {
        let override = UserDefaults.standard.integer(forKey: Keys.serialOverride(service))
        let serial = override > 0 ? override : (detectedSerials[service] ?? 1)
        return ServiceAccount(serial: serial, desc: serviceDescs[service] ?? service.defaultDesc)
    }

    static func serialOverrideKey(_ service: StreamingService) -> String { Keys.serialOverride(service) }

    /// 再生中の曲がどのサービスのものか
    var currentService: StreamingService? {
        guard let track else { return nil }
        return StreamingService.detect(in: track.uri) ?? StreamingService.detect(in: track.rawMetadata)
    }

    // MARK: Internal bookkeeping

    @ObservationIgnored private let discovery = SonosDiscovery()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var seekLockUntil = Date.distantPast
    @ObservationIgnored private var stateLockUntil = Date.distantPast
    @ObservationIgnored private var modeLockUntil = Date.distantPast
    @ObservationIgnored private var volumeLockUntil = Date.distantPast
    @ObservationIgnored private var memberVolumeLocks: [String: Date] = [:]
    @ObservationIgnored private var needsVolumeSnapshot = true
    @ObservationIgnored private var memberSenders: [String: LatestValueSender] = [:]
    @ObservationIgnored private var deviceCache: [String: DeviceDescription] = [:]
    @ObservationIgnored private var serviceDescs: [StreamingService: String] = [:]
    @ObservationIgnored private var didInitialLoad = false
    @ObservationIgnored private var groupVolumeSender: LatestValueSender!

    private init() {
        groupVolumeSender = LatestValueSender { [weak self] value in
            guard let self, let client = self.coordinatorClient else { return }
            if self.needsVolumeSnapshot {
                self.needsVolumeSnapshot = false
                try? await client.snapshotGroupVolume()
            }
            try await client.setGroupVolume(value)
        }
    }

    private var coordinatorClient: SOAPClient? {
        selectedGroup.map { SOAPClient(host: $0.coordinator.host) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        discovery.onHostFound = { [weak self] host in self?.discovered(host) }
        discovery.start()
        startPolling()
    }

    func resume() {
        guard started else { return }
        discovery.start()
        startPolling()
    }

    func suspend() {
        pollTask?.cancel()
        pollTask = nil
        discovery.stop()
    }

    func rediscover() {
        discovery.stop()
        discovery.start()
        Task { await refreshTopology() }
    }

    func addManualHost(_ input: String) async -> Bool {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        guard let found = try? await SOAPClient(host: host).zoneGroups(), !found.isEmpty else {
            show(message: "\(host) にSonosスピーカーが見つかりませんでした")
            return false
        }
        remember(host)
        applyTopology(found)
        return true
    }

    private func discovered(_ host: String) {
        remember(host)
        let known = groups.contains { $0.members.contains { $0.host == host } }
        if !known { Task { await refreshTopology(preferring: host) } }
    }

    private func remember(_ host: String) {
        guard !knownHosts.contains(host) else { return }
        knownHosts = Array(([host] + knownHosts).prefix(12))
        UserDefaults.standard.set(knownHosts, forKey: Keys.hosts)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(includeSlow: tick % 3 == 0, includeTopology: tick % 15 == 0)
                tick &+= 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollImmediately() async {
        await poll(includeSlow: true, includeTopology: false)
    }

    private func poll(includeSlow: Bool, includeTopology: Bool) async {
        if groups.isEmpty {
            if includeSlow { await refreshTopology() }
            return
        }
        if includeTopology { await refreshTopology() }
        guard let group = selectedGroup else { return }
        let client = SOAPClient(host: group.coordinator.host)

        do {
            async let positionRequest = client.positionInfo()
            async let stateRequest = client.transportState()
            let position = try await positionRequest
            let state = try await stateRequest
            if includeSlow || mediaInfo == nil { await pollSlow(client: client, group: group) }
            guard group.coordinator.uuid == selectedGroup?.coordinator.uuid else { return }
            apply(position: position, state: state, group: group)
            failureCount = 0
            if connection != .connected { connection = .connected }
        } catch {
            failureCount += 1
            if failureCount >= 3 {
                connection = .unreachable
                if failureCount % 3 == 0 { await refreshTopology() }
            }
        }
    }

    private func pollSlow(client: SOAPClient, group: SonosGroup) async {
        if let media = try? await client.mediaInfo() {
            let countChanged = media.numberOfTracks != mediaInfo?.numberOfTracks
            if media != mediaInfo { mediaInfo = media }
            if countChanged && isPlayingQueue { Task { await refreshQueue() } }
        }
        if Date() >= modeLockUntil, let mode = try? await client.playMode(), mode != playMode {
            playMode = mode
        }
        if Date() >= volumeLockUntil {
            if let volume = try? await client.groupVolume(), Date() >= volumeLockUntil, volume != groupVolume {
                groupVolume = volume
            }
            if let muted = try? await client.groupMute(), muted != groupMuted { groupMuted = muted }
        }
        if track?.kind == .tv, let q = await homeTheaterQuality(group), q != quality {
            quality = q
        }
    }

    private func apply(position: PositionInfo, state: TransportState, group: SonosGroup) {
        let previousState = transportState
        if Date() >= stateLockUntil, state != transportState { transportState = state }

        let newTrack = TrackInfo.make(position: position, media: mediaInfo, host: group.coordinator.host)
        let changed = newTrack?.identity != track?.identity
        if newTrack != track { track = newTrack }
        if currentTrackNumber != position.trackNumber { currentTrackNumber = position.trackNumber }

        if Date() >= seekLockUntil {
            reanchor(reported: position.position, force: changed || previousState != transportState || transportState != .playing)
        }
        if changed { trackDidChange() }
    }

    /// Sonosの再生位置は秒単位で切り捨てられるので、遅れているときだけ前に合わせる
    private func reanchor(reported: Double, force: Bool) {
        let predicted = position()
        if force || reported > predicted + 0.05 || predicted - reported > 1.5 {
            positionSeconds = reported
            positionDate = Date()
        }
    }

    private func trackDidChange() {
        quality = nil
        trackNames = nil
        guard let track, let group = selectedGroup else {
            lyrics.clear()
            return
        }
        switch track.kind {
        case .track, .radio:
            lyrics.load(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
        case .tv, .lineIn:
            lyrics.clear()
        }
        learnAccounts(from: [track.uri, track.rawMetadata])
        let identity = track.identity
        Task {
            var resolved = await self.resolveQuality(track, group: group)
            if resolved?.badge == nil {
                // 曲が変わった直後はスピーカーがまだ品質を知らないことがあるので、少し待ってもう一度
                try? await Task.sleep(for: .seconds(3))
                guard self.track?.identity == identity else { return }
                resolved = await self.resolveQuality(track, group: group) ?? resolved
            }
            if self.track?.identity == identity { self.quality = resolved }
        }
        localizeNames(track)
    }

    /// Apple Music の曲名がローマ字なら、カタログで日本語表記を探す
    private func localizeNames(_ track: TrackInfo) {
        guard track.kind == .track, StreamingService.detect(in: track.uri) == .appleMusic,
              TrackNameLocalizer.needsLookup(title: track.title, artist: track.artist) else { return }
        let identity = track.identity
        Task {
            let names = await TrackNameLocalizer.shared.names(
                title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                catalogSongID: AppleMusicSonos.catalogSongID(in: track.uri))
            guard let names, self.track?.identity == identity else { return }
            self.trackNames = names
            // ローマ字では歌詞が見つからなかった曲は、日本語表記でもう一度探す
            if case .notFound = self.lyrics.state {
                self.lyrics.load(title: names.title, artist: names.artist, album: names.album ?? track.album,
                                 duration: track.duration)
            }
        }
    }

    // MARK: - Topology

    func refreshTopology(preferring preferred: String? = nil) async {
        var hosts: [String] = []
        if let preferred { hosts.append(preferred) }
        if let group = selectedGroup { hosts.append(group.coordinator.host) }
        hosts += groups.flatMap { $0.members.map(\.host) }
        hosts += knownHosts
        for host in hosts.uniqued() {
            if let found = try? await SOAPClient(host: host).zoneGroups(), !found.isEmpty {
                applyTopology(found)
                return
            }
        }
        if groups.isEmpty { connection = .searching }
    }

    private func applyTopology(_ newGroups: [SonosGroup]) {
        let previousCoordinator = selectedGroup?.coordinator.uuid
        if newGroups != groups { groups = newGroups }
        newGroups.flatMap(\.members).forEach { remember($0.host) }

        if let group = selectedGroup, group.coordinator.uuid != selectedCoordinatorID {
            selectedCoordinatorID = group.coordinator.uuid
            UserDefaults.standard.set(group.coordinator.uuid, forKey: Keys.selected)
        }
        connection = .connected

        if selectedGroup?.coordinator.uuid != previousCoordinator {
            resetPlaybackState()
            Task { await self.pollImmediately() }
        }
        if !didInitialLoad {
            didInitialLoad = true
            Task {
                await self.loadFavorites()
                await self.detectServiceAccounts()
            }
        }
    }

    func select(group: SonosGroup) {
        guard group.coordinator.uuid != selectedGroup?.coordinator.uuid else { return }
        selectedCoordinatorID = group.coordinator.uuid
        UserDefaults.standard.set(group.coordinator.uuid, forKey: Keys.selected)
        resetPlaybackState()
        Task { await pollImmediately() }
    }

    private func resetPlaybackState() {
        track = nil
        mediaInfo = nil
        queue = []
        quality = nil
        memberVolumes = [:]
        currentTrackNumber = 0
        positionSeconds = 0
        positionDate = Date()
        needsVolumeSnapshot = true
        lyrics.clear()
    }

    func add(_ speaker: SonosSpeaker) {
        guard let group = selectedGroup else { return }
        Task {
            do {
                try await SOAPClient(host: speaker.host).joinGroup(coordinatorUUID: group.coordinator.uuid)
            } catch {
                show(error)
            }
            try? await Task.sleep(for: .milliseconds(700))
            await refreshTopology()
            await refreshMemberVolumes()
        }
    }

    func remove(_ speaker: SonosSpeaker) {
        Task {
            do {
                try await SOAPClient(host: speaker.host).becomeStandalone()
            } catch {
                show(error)
            }
            try? await Task.sleep(for: .milliseconds(700))
            await refreshTopology()
        }
    }

    // MARK: - Transport commands

    private func run(_ operation: @escaping @MainActor (SOAPClient) async throws -> Void) {
        guard let client = coordinatorClient else {
            show(SonosError.noGroup)
            return
        }
        Task {
            do {
                try await operation(client)
            } catch {
                self.stateLockUntil = .distantPast
                self.modeLockUntil = .distantPast
                self.seekLockUntil = .distantPast
                self.show(error)
            }
            await self.pollImmediately()
        }
    }

    func togglePlayPause() {
        let wasPlaying = isPlaying
        positionSeconds = position()
        positionDate = Date()
        transportState = wasPlaying ? .paused : .playing
        stateLockUntil = Date().addingTimeInterval(1.5)
        run { client in
            if wasPlaying {
                do {
                    try await client.pause()
                } catch SonosError.upnp(let code, _) where code == 701 {
                    try await client.stop() // 一時停止できないライブ配信
                }
            } else {
                try await client.play()
            }
        }
    }

    func next() {
        run { try await $0.next() }
    }

    func previous() {
        if duration > 0, position() > 3 {
            seek(to: 0)
        } else {
            run { try await $0.previous() }
        }
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(seconds, duration - 0.5))
        positionSeconds = target
        positionDate = Date()
        seekLockUntil = Date().addingTimeInterval(2)
        run { try await $0.seek(to: target) }
    }

    func toggleShuffle() {
        var mode = playMode
        mode.shuffle.toggle()
        setPlayMode(mode)
    }

    func cycleRepeat() {
        var mode = playMode
        switch mode.repeatMode {
        case .off: mode.repeatMode = .all
        case .all: mode.repeatMode = .one
        case .one: mode.repeatMode = .off
        }
        setPlayMode(mode)
    }

    private func setPlayMode(_ mode: PlayMode) {
        playMode = mode
        modeLockUntil = Date().addingTimeInterval(2)
        run { try await $0.setPlayMode(mode.sonosValue) }
    }

    // MARK: - Volume

    /// 音量操作の開始時に呼ぶ（グループ内の音量バランスを記録し直す）
    func beginVolumeChange() {
        needsVolumeSnapshot = true
        volumeLockUntil = Date().addingTimeInterval(2)
    }

    func setGroupVolume(_ value: Int) {
        let volume = max(0, min(100, value))
        volumeLockUntil = Date().addingTimeInterval(2)
        guard volume != groupVolume else { return }
        groupVolume = volume
        groupVolumeSender.submit(volume)
    }

    func toggleMute() {
        let muted = !groupMuted
        groupMuted = muted
        run { try await $0.setGroupMute(muted) }
    }

    func setMemberVolume(_ speaker: SonosSpeaker, _ value: Int) {
        let volume = max(0, min(100, value))
        memberVolumes[speaker.uuid] = volume
        memberVolumeLocks[speaker.uuid] = Date().addingTimeInterval(2)
        needsVolumeSnapshot = true
        let sender = memberSenders[speaker.uuid] ?? LatestValueSender { value in
            try await SOAPClient(host: speaker.host).setVolume(value)
        }
        memberSenders[speaker.uuid] = sender
        sender.submit(volume)
    }

    func refreshMemberVolumes() async {
        guard let group = selectedGroup else { return }
        for member in group.members {
            guard let volume = try? await SOAPClient(host: member.host).volume() else { continue }
            if Date() >= memberVolumeLocks[member.uuid, default: .distantPast] {
                memberVolumes[member.uuid] = volume
            }
        }
        if Date() >= volumeLockUntil, let client = coordinatorClient, let volume = try? await client.groupVolume() {
            groupVolume = volume
        }
    }

    // MARK: - Queue

    func refreshQueue() async {
        guard let client = coordinatorClient else { return }
        var items: [DIDLItem] = []
        var start = 0
        while start < 1000 {
            guard let result = try? await client.browse("Q:0", start: start, count: 100) else { break }
            items += result.items
            start += result.items.count
            if result.items.isEmpty || start >= result.total { break }
        }
        if items != queue { queue = items }
    }

    func playQueueItem(at index: Int) {
        guard let group = selectedGroup else { return }
        let needsQueue = !isPlayingQueue
        let queueURI = "x-rincon-queue:\(group.coordinator.uuid)#0"
        run { client in
            if needsQueue { try await client.setAVTransportURI(queueURI, metadata: "") }
            try await client.seek(trackNumber: index + 1)
            try await client.play()
        }
    }

    func removeQueueItems(at offsets: IndexSet) {
        let positions = offsets.sorted(by: >).map { $0 + 1 }
        queue.remove(atOffsets: offsets)
        run { client in
            for position in positions { try await client.removeTrackFromQueue(position: position) }
            await self.refreshQueue()
        }
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first else { return }
        queue.move(fromOffsets: source, toOffset: destination)
        run { client in
            try await client.reorderQueue(start: from + 1, count: 1, insertBefore: destination + 1)
            await self.refreshQueue()
        }
    }

    func clearQueue() {
        queue = []
        run { try await $0.removeAllTracksFromQueue() }
    }

    // MARK: - Playing content

    nonisolated static let streamPrefixes = [
        "x-sonosapi-stream:", "x-sonosapi-radio:", "x-rincon-mp3radio:", "x-sonosapi-hls:",
        "x-sonosapi-hls-static:", "aac:", "hls-radio:", "x-sonos-htastream:", "x-rincon-stream:", "x-rincon:",
    ]

    nonisolated static func isStreamURI(_ uri: String) -> Bool {
        streamPrefixes.contains { uri.hasPrefix($0) }
    }

    /// キューを置き換えて再生（Apple Musicの「再生」と同じ動き）
    func replaceQueueAndPlay(candidates: [(uri: String, metadata: String)], startTrack: Int = 1, shuffle: Bool? = nil) {
        guard let group = selectedGroup else {
            show(SonosError.noGroup)
            return
        }
        let queueURI = "x-rincon-queue:\(group.coordinator.uuid)#0"
        run { client in
            try await client.removeAllTracksFromQueue()
            var lastError: Error?
            var added = false
            for candidate in candidates {
                do {
                    try await client.addURIToQueue(candidate.uri, metadata: candidate.metadata, position: 0, asNext: false)
                    added = true
                    break
                } catch {
                    lastError = error
                }
            }
            if !added, let lastError { throw lastError }
            try await client.setAVTransportURI(queueURI, metadata: "")
            if let shuffle {
                var mode = self.playMode
                mode.shuffle = shuffle
                try await client.setPlayMode(mode.sonosValue)
                self.playMode = mode
            }
            if startTrack > 1 { try await client.seek(trackNumber: startTrack) }
            try await client.play()
            await self.refreshQueue()
        }
    }

    func enqueue(candidates: [(uri: String, metadata: String)], mode: EnqueueMode) {
        let nextPosition = isPlayingQueue && currentTrackNumber > 0 ? currentTrackNumber + 1 : 0
        run { client in
            var lastError: Error?
            for candidate in candidates {
                do {
                    try await client.addURIToQueue(candidate.uri, metadata: candidate.metadata,
                                                   position: mode == .next ? nextPosition : 0, asNext: mode == .next)
                    self.show(message: mode == .next ? "次に再生に追加しました" : "キューの最後に追加しました")
                    await self.refreshQueue()
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
        }
    }

    private func setTransportAndPlay(uri: String, metadata: String) {
        run { client in
            try await client.setAVTransportURI(uri, metadata: metadata)
            try await client.play()
        }
    }

    func playFavorite(_ favorite: DIDLItem) {
        guard let uri = favorite.resURI else { return }
        let metadata = favorite.resMD ?? ""
        if Self.isStreamURI(uri) {
            setTransportAndPlay(uri: uri, metadata: metadata)
        } else {
            replaceQueueAndPlay(candidates: [(uri, metadata)])
        }
    }

    /// ライブラリ / プレイリスト内のアイテムを再生。container を渡すと、その位置からコンテナ全体を再生する
    func play(_ item: DIDLItem, in container: DIDLItem? = nil, index: Int = 0, shuffle: Bool? = nil) {
        if item.isFavorite {
            playFavorite(item)
            return
        }
        if let container, let containerURI = container.resURI, !item.isContainer {
            replaceQueueAndPlay(candidates: [(containerURI, DIDL.metadata(for: container))], startTrack: index + 1, shuffle: shuffle)
            return
        }
        guard let uri = item.resURI else { return }
        if Self.isStreamURI(uri) {
            setTransportAndPlay(uri: uri, metadata: DIDL.metadata(for: item))
        } else {
            replaceQueueAndPlay(candidates: [(uri, DIDL.metadata(for: item))], shuffle: shuffle)
        }
    }

    func enqueue(_ item: DIDLItem, mode: EnqueueMode) {
        guard let uri = item.resURI else { return }
        if Self.isStreamURI(uri) {
            show(message: "ラジオ局はキューに追加できません")
            return
        }
        enqueue(candidates: [(uri, DIDL.metadata(for: item))], mode: mode)
    }

    func playAppleMusic(_ content: AppleMusicSonos.Content, startIndex: Int = 0, shuffle: Bool? = nil) {
        play(content.serviceContent, startIndex: startIndex, shuffle: shuffle)
    }

    func enqueueAppleMusic(_ content: AppleMusicSonos.Content, mode: EnqueueMode) {
        enqueue(content.serviceContent, mode: mode)
    }

    /// Apple Music / Spotify / Amazon Music の曲・アルバム・プレイリストを、Sonosに登録済みのアカウントで再生する
    func play(_ content: ServiceContent, startIndex: Int = 0, shuffle: Bool? = nil) {
        let candidates = SonosServiceURI.candidates(for: content, account: account(for: content.service))
        replaceQueueAndPlay(candidates: candidates, startTrack: startIndex + 1, shuffle: shuffle)
    }

    func enqueue(_ content: ServiceContent, mode: EnqueueMode) {
        enqueue(candidates: SonosServiceURI.candidates(for: content, account: account(for: content.service)), mode: mode)
    }

    // MARK: - Browse

    func browse(_ objectID: String, start: Int = 0, count: Int = 200) async throws -> BrowseResult {
        guard let client = coordinatorClient else { throw SonosError.noGroup }
        return try await client.browse(objectID, start: start, count: count)
    }

    func loadFavorites() async {
        guard let result = try? await browse("FV:2", count: 200) else { return }
        favorites = result.items
        learnAccounts(from: result.items.flatMap { [$0.resURI ?? "", $0.resMD ?? ""] })
    }

    /// お気に入りをサービスで絞り込む（nil はすべて）
    func favorites(for service: StreamingService?) -> [DIDLItem] {
        guard let service else { return favorites }
        return favorites.filter { StreamingService.detect($0) == service }
    }

    private func detectServiceAccounts() async {
        guard let client = coordinatorClient else { return }
        if let accounts = try? await client.accounts() {
            for service in StreamingService.allCases {
                if let account = accounts.first(where: { $0.type == service.sonosServiceType }) {
                    linkedServices.insert(service)
                    if detectedSerials[service] == nil { detectedSerials[service] = account.serial }
                }
            }
        }
        if queue.isEmpty { await refreshQueue() }
        learnAccounts(from: favorites.flatMap { [$0.resURI ?? "", $0.resMD ?? ""] } + queue.map { $0.resURI ?? "" })
    }

    /// お気に入りや再生中の URI から、サービスごとのアカウント番号と desc を覚える
    private func learnAccounts(from texts: [String]) {
        for text in texts where !text.isEmpty {
            guard let service = StreamingService.detect(in: text) else { continue }
            linkedServices.insert(service)
            if detectedSerials[service] == nil, let serial = service.serial(in: text) {
                detectedSerials[service] = serial
            }
            if serviceDescs[service] == nil, let desc = service.desc(in: text) {
                serviceDescs[service] = desc
            }
        }
    }

    // MARK: - Settings-ish

    func refreshPlaybackOptions() async {
        guard let client = coordinatorClient else { return }
        crossfade = (try? await client.crossfadeMode()) ?? false
        sleepTimerRemaining = try? await client.remainingSleepTimer()
    }

    func setCrossfade(_ on: Bool) {
        crossfade = on
        run { try await $0.setCrossfadeMode(on) }
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerRemaining = minutes.map { $0 * 60 }
        run { client in
            try await client.configureSleepTimer(seconds: minutes.map { $0 * 60 })
            self.show(message: minutes.map { "\($0)分後に停止します" } ?? "スリープタイマーをオフにしました")
        }
    }

    // MARK: - Quality

    private func resolveQuality(_ track: TrackInfo, group: SonosGroup) async -> AudioQuality? {
        if track.kind == .tv { return await homeTheaterQuality(group) }
        // 純正 Sonos アプリと同じ情報（スピーカーが実際に受け取っている音源の品質）
        if let reported = await SonosLocalAPI.shared.currentTrack(host: group.coordinator.host)?.quality,
           let sonos = AudioQualityDetector.fromSonos(reported) {
            return sonos
        }
        let streamQuality = AudioQualityDetector.fromStream(track)
        if streamQuality?.badge != nil { return streamQuality }
        if let songID = AppleMusicSonos.catalogSongID(in: track.uri) {
            let traits = await AppleMusicService.shared.audioTraits(type: .songs, id: songID)
            let atmos = await supportsAtmos(group.coordinator)
            if let catalog = AudioQualityDetector.fromAppleMusic(traits: traits, speakerSupportsAtmos: atmos) {
                return catalog
            }
        }
        return streamQuality
    }

    private func homeTheaterQuality(_ group: SonosGroup) async -> AudioQuality? {
        guard let info = try? await SOAPClient(host: group.coordinator.host).zoneInfo(),
              let code = Int(info["HTAudioIn"] ?? "") else { return nil }
        return AudioQualityDetector.fromHomeTheater(code: code)
    }

    private func supportsAtmos(_ speaker: SonosSpeaker) async -> Bool {
        if let cached = deviceCache[speaker.uuid] { return cached.supportsAtmos }
        guard let description = try? await SOAPClient(host: speaker.host).deviceDescription() else { return false }
        deviceCache[speaker.uuid] = description
        return description.supportsAtmos
    }

    // MARK: - Toast

    func show(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    func show(message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast == message { self.toast = nil }
        }
    }
}
