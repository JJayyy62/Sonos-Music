import Foundation

/// Sonos の各アクション
extension SOAPClient {
    private static let instance = ("InstanceID", "0")

    // MARK: AVTransport

    func play() async throws {
        try await call(.avTransport, "Play", [Self.instance, ("Speed", "1")])
    }

    func pause() async throws {
        try await call(.avTransport, "Pause", [Self.instance])
    }

    func stop() async throws {
        try await call(.avTransport, "Stop", [Self.instance])
    }

    func next() async throws {
        try await call(.avTransport, "Next", [Self.instance])
    }

    func previous() async throws {
        try await call(.avTransport, "Previous", [Self.instance])
    }

    func seek(to seconds: Double) async throws {
        try await call(.avTransport, "Seek", [Self.instance, ("Unit", "REL_TIME"), ("Target", TimeFormat.sonos(seconds))])
    }

    func seek(trackNumber: Int) async throws {
        try await call(.avTransport, "Seek", [Self.instance, ("Unit", "TRACK_NR"), ("Target", String(trackNumber))])
    }

    func positionInfo() async throws -> PositionInfo {
        let r = try await call(.avTransport, "GetPositionInfo", [Self.instance])
        return PositionInfo(
            trackNumber: Int(r["Track"] ?? "") ?? 0,
            duration: TimeFormat.parse(r["TrackDuration"] ?? "") ?? 0,
            position: TimeFormat.parse(r["RelTime"] ?? "") ?? 0,
            uri: r["TrackURI"] ?? "",
            metadata: r["TrackMetaData"] ?? "")
    }

    func transportState() async throws -> TransportState {
        let r = try await call(.avTransport, "GetTransportInfo", [Self.instance])
        return TransportState(rawValue: r["CurrentTransportState"] ?? "") ?? .stopped
    }

    func playMode() async throws -> PlayMode {
        let r = try await call(.avTransport, "GetTransportSettings", [Self.instance])
        return PlayMode(sonos: r["PlayMode"] ?? "NORMAL")
    }

    func setPlayMode(_ value: String) async throws {
        try await call(.avTransport, "SetPlayMode", [Self.instance, ("NewPlayMode", value)])
    }

    func mediaInfo() async throws -> MediaInfo {
        let r = try await call(.avTransport, "GetMediaInfo", [Self.instance])
        return MediaInfo(currentURI: r["CurrentURI"] ?? "",
                         currentURIMetaData: r["CurrentURIMetaData"] ?? "",
                         numberOfTracks: Int(r["NrTracks"] ?? "") ?? 0)
    }

    func setAVTransportURI(_ uri: String, metadata: String) async throws {
        try await call(.avTransport, "SetAVTransportURI",
                       [Self.instance, ("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
    }

    /// position: 0 なら末尾、asNext: true なら現在の曲の次
    @discardableResult
    func addURIToQueue(_ uri: String, metadata: String, position: Int, asNext: Bool) async throws -> Int {
        let r = try await call(.avTransport, "AddURIToQueue", [
            Self.instance,
            ("EnqueuedURI", uri),
            ("EnqueuedURIMetaData", metadata),
            ("DesiredFirstTrackNumberEnqueued", String(position)),
            ("EnqueueAsNext", asNext ? "1" : "0"),
        ])
        return Int(r["FirstTrackNumberEnqueued"] ?? "") ?? 0
    }

    func removeAllTracksFromQueue() async throws {
        try await call(.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
    }

    /// position は1始まり
    func removeTrackFromQueue(position: Int) async throws {
        try await call(.avTransport, "RemoveTrackFromQueue",
                       [Self.instance, ("ObjectID", "Q:0/\(position)"), ("UpdateID", "0")])
    }

    func reorderQueue(start: Int, count: Int, insertBefore: Int) async throws {
        try await call(.avTransport, "ReorderTracksInQueue", [
            Self.instance,
            ("StartingIndex", String(start)),
            ("NumberOfTracks", String(count)),
            ("InsertBefore", String(insertBefore)),
            ("UpdateID", "0"),
        ])
    }

    func becomeStandalone() async throws {
        try await call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [Self.instance])
    }

    func joinGroup(coordinatorUUID: String) async throws {
        try await setAVTransportURI("x-rincon:\(coordinatorUUID)", metadata: "")
    }

    func configureSleepTimer(seconds: Int?) async throws {
        let value = seconds.map { TimeFormat.sonos(Double($0)) } ?? ""
        try await call(.avTransport, "ConfigureSleepTimer", [Self.instance, ("NewSleepTimerDuration", value)])
    }

    func remainingSleepTimer() async throws -> Int? {
        let r = try await call(.avTransport, "GetRemainingSleepTimerDuration", [Self.instance])
        guard let seconds = TimeFormat.parse(r["RemainingSleepTimerDuration"] ?? ""), seconds > 0 else { return nil }
        return Int(seconds)
    }

    func crossfadeMode() async throws -> Bool {
        let r = try await call(.avTransport, "GetCrossfadeMode", [Self.instance])
        return r["CrossfadeMode"] == "1"
    }

    func setCrossfadeMode(_ on: Bool) async throws {
        try await call(.avTransport, "SetCrossfadeMode", [Self.instance, ("CrossfadeMode", on ? "1" : "0")])
    }

    // MARK: Volume

    func volume() async throws -> Int {
        let r = try await call(.renderingControl, "GetVolume", [Self.instance, ("Channel", "Master")])
        return Int(r["CurrentVolume"] ?? "") ?? 0
    }

    func setVolume(_ value: Int) async throws {
        try await call(.renderingControl, "SetVolume",
                       [Self.instance, ("Channel", "Master"), ("DesiredVolume", String(value))])
    }

    func groupVolume() async throws -> Int {
        let r = try await call(.groupRenderingControl, "GetGroupVolume", [Self.instance])
        return Int(r["CurrentVolume"] ?? "") ?? 0
    }

    func setGroupVolume(_ value: Int) async throws {
        try await call(.groupRenderingControl, "SetGroupVolume", [Self.instance, ("DesiredVolume", String(value))])
    }

    /// グループ内の音量比率を記録（SetGroupVolume の前に呼ぶ）
    func snapshotGroupVolume() async throws {
        try await call(.groupRenderingControl, "SnapshotGroupVolume", [Self.instance])
    }

    func groupMute() async throws -> Bool {
        let r = try await call(.groupRenderingControl, "GetGroupMute", [Self.instance])
        return r["CurrentMute"] == "1"
    }

    func setGroupMute(_ on: Bool) async throws {
        try await call(.groupRenderingControl, "SetGroupMute", [Self.instance, ("DesiredMute", on ? "1" : "0")])
    }

    // MARK: ContentDirectory

    func browse(_ objectID: String, start: Int = 0, count: Int = 100) async throws -> BrowseResult {
        let r = try await call(.contentDirectory, "Browse", [
            ("ObjectID", objectID),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "*"),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SortCriteria", ""),
        ])
        let items = DIDL.parse(r["Result"] ?? "")
        return BrowseResult(items: items, total: Int(r["TotalMatches"] ?? "") ?? items.count)
    }

    // MARK: Topology / Device

    func zoneGroups() async throws -> [SonosGroup] {
        let r = try await call(.zoneGroupTopology, "GetZoneGroupState")
        return Topology.parse(r["ZoneGroupState"] ?? "")
    }

    func zoneInfo() async throws -> [String: String] {
        try await call(.deviceProperties, "GetZoneInfo")
    }

    func deviceDescription() async throws -> DeviceDescription {
        let data = try await get("/xml/device_description.xml")
        guard let device = XMLTreeParser.parse(data: data)?.firstDescendant("device") else {
            throw SonosError.invalidResponse
        }
        return DeviceDescription(
            modelName: device.first("modelName")?.trimmedText ?? "",
            modelNumber: device.first("modelNumber")?.trimmedText ?? "",
            displayName: device.first("displayName")?.trimmedText ?? "")
    }

    /// 登録済みの音楽サービスアカウント（ファームウェアによっては無効）
    func accounts() async throws -> [SonosAccount] {
        let data = try await get("/status/accounts")
        guard let root = XMLTreeParser.parse(data: data) else { return [] }
        return root.descendants(named: "Account").compactMap { node in
            guard node.attributes["Deleted"] != "1",
                  let type = Int(node.attributes["Type"] ?? ""),
                  let serial = Int(node.attributes["SerialNum"] ?? "") else { return nil }
            return SonosAccount(type: type, serial: serial)
        }
    }
}

enum Topology {
    static func parse(_ xml: String) -> [SonosGroup] {
        guard let root = XMLTreeParser.parse(string: xml) else { return [] }
        let groupNodes = root.name == "ZoneGroup" ? [root] : root.descendants(named: "ZoneGroup")
        var groups: [SonosGroup] = []

        for node in groupNodes {
            let coordinatorID = node.attributes["Coordinator"] ?? ""
            var coordinator: SonosSpeaker?
            var members: [SonosSpeaker] = []

            for member in node.all("ZoneGroupMember") {
                guard let uuid = member.attributes["UUID"],
                      let location = member.attributes["Location"],
                      let host = URL(string: location)?.host else { continue }
                let speaker = SonosSpeaker(uuid: uuid, roomName: member.attributes["ZoneName"] ?? "Sonos", host: host)
                if uuid == coordinatorID { coordinator = speaker }
                let hidden = member.attributes["Invisible"] == "1" || member.attributes["IsZoneBridge"] == "1"
                if !hidden { members.append(speaker) }
            }

            guard let coordinator, !members.isEmpty else { continue }
            if !members.contains(where: { $0.uuid == coordinator.uuid }) { members.insert(coordinator, at: 0) }
            members.sort { a, b in
                if a.uuid == coordinatorID { return true }
                if b.uuid == coordinatorID { return false }
                return a.roomName.localizedStandardCompare(b.roomName) == .orderedAscending
            }
            groups.append(SonosGroup(id: node.attributes["ID"] ?? coordinatorID, coordinator: coordinator, members: members))
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
