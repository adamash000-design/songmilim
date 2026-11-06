import Foundation

@MainActor
@Observable
final class SonosStore {
    static let shared = SonosStore()

    enum State: Equatable { case idle, searching, ready, failed(String) }

    private(set) var groups: [SonosGroup] = []
    private(set) var nowPlaying: [String: NowPlaying] = [:]   // לפי מזהה הקבוצה
    private(set) var groupVolumes: [String: Int] = [:]
    private(set) var favorites: [SonosFavorite] = []
    private(set) var state: State = .idle

    /// כתובת ידנית (אם הגילוי האוטומטי לא עובד ברשת שלך)
    var manualHost: String {
        get { UserDefaults.standard.string(forKey: "sonos.manualHost") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "sonos.manualHost") }
    }

    private var lastHost: String? {
        get { UserDefaults.standard.string(forKey: "sonos.lastHost") }
        set { UserDefaults.standard.set(newValue, forKey: "sonos.lastHost") }
    }

    var allPlayers: [SonosPlayer] {
        groups.flatMap(\.members).sorted { $0.name < $1.name }
    }

    func group(containing playerID: String) -> SonosGroup? {
        groups.first { $0.members.contains { $0.id == playerID } }
    }

    // MARK: רענון

    func refresh() async {
        if groups.isEmpty { state = .searching }
        do {
            let host = try await reachableHost()
            lastHost = host
            state = .ready
            await withTaskGroup(of: Void.self) { tasks in
                for group in groups {
                    tasks.addTask { await self.updateStatus(of: group) }
                }
            }
            if favorites.isEmpty { await loadFavorites(host: host) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func reachableHost() async throws -> String {
        let candidates = [manualHost, lastHost ?? ""]
            .filter(SonosClient.isValidLocalHost)
        for host in candidates {
            if let found = try? await fetchGroups(from: host) {
                groups = found
                return host
            }
        }
        let discovered = try await SonosDiscovery.findHost()
        groups = try await fetchGroups(from: discovered)
        return discovered
    }

    private func fetchGroups(from host: String) async throws -> [SonosGroup] {
        let response = try await SonosClient.call(host, .zoneGroupTopology, "GetZoneGroupState")
        guard let xml = response["ZoneGroupState"] else { throw SonosError.notFound }
        let parsed = ZoneGroupParser.parse(xml).sorted { $0.name < $1.name }
        guard !parsed.isEmpty else { throw SonosError.notFound }
        return parsed
    }

    private func updateStatus(of group: SonosGroup) async {
        let host = group.coordinator.host
        let instance = [("InstanceID", "0")]
        async let transport = try? SonosClient.call(host, .avTransport, "GetTransportInfo", instance)
        async let position = try? SonosClient.call(host, .avTransport, "GetPositionInfo", instance)
        async let volume = try? SonosClient.call(host, .groupRenderingControl, "GetGroupVolume", instance)
        let (t, p, v) = await (transport, position, volume)

        var info = NowPlaying()
        info.isPlaying = t?["CurrentTransportState"] == "PLAYING"
        if let meta = p?["TrackMetaData"], meta != "NOT_IMPLEMENTED",
           let item = DIDLParser.parse(meta).first {
            info.title = item.fields["dc:title"] ?? ""
            info.artist = item.fields["dc:creator"] ?? ""
            info.album = item.fields["upnp:album"] ?? ""
            if let stream = item.fields["r:streamContent"], !stream.isEmpty { info.artist = stream }
            info.artURL = SonosClient.artURL(item.fields["upnp:albumArtURI"], host: host)
        }
        nowPlaying[group.id] = info
        if let raw = v?["CurrentVolume"], let level = Int(raw) { groupVolumes[group.id] = level }
    }

    private func loadFavorites(host: String) async {
        let args = [
            ("ObjectID", "FV:2"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
            ("StartingIndex", "0"), ("RequestedCount", "100"), ("SortCriteria", ""),
        ]
        guard let response = try? await SonosClient.call(host, .contentDirectory, "Browse", args),
              let result = response["Result"] else { return }
        favorites = DIDLParser.parse(result).compactMap { item in
            guard let uri = item.fields["res"], !uri.isEmpty else { return nil }
            return SonosFavorite(
                id: item.id,
                title: item.fields["dc:title"] ?? "",
                uri: uri,
                metadata: item.fields["r:resMD"] ?? "",
                artURL: SonosClient.artURL(item.fields["upnp:albumArtURI"], host: host)
            )
        }
    }

    // MARK: פקודות

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { state = .failed(error.localizedDescription) }
    }

    func togglePlay(_ group: SonosGroup) async {
        if nowPlaying[group.id]?.isPlaying == true { await pause(group) } else { await play(group) }
    }

    func play(_ group: SonosGroup) async {
        await run {
            try await SonosClient.call(group.coordinator.host, .avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        }
        await updateStatus(of: group)
    }

    func pause(_ group: SonosGroup) async {
        await run {
            try await SonosClient.call(group.coordinator.host, .avTransport, "Pause", [("InstanceID", "0")])
        }
        await updateStatus(of: group)
    }

    func pauseAll() async {
        for group in groups {
            try? await SonosClient.call(group.coordinator.host, .avTransport, "Pause", [("InstanceID", "0")])
        }
        await refresh()
    }

    func next(_ group: SonosGroup) async {
        await run { try await SonosClient.call(group.coordinator.host, .avTransport, "Next", [("InstanceID", "0")]) }
        await updateStatus(of: group)
    }

    func previous(_ group: SonosGroup) async {
        await run { try await SonosClient.call(group.coordinator.host, .avTransport, "Previous", [("InstanceID", "0")]) }
        await updateStatus(of: group)
    }

    func setGroupVolume(_ group: SonosGroup, _ level: Int) async {
        let host = group.coordinator.host
        await run {
            try await SonosClient.call(host, .groupRenderingControl, "SnapshotGroupVolume", [("InstanceID", "0")])
            try await SonosClient.call(host, .groupRenderingControl, "SetGroupVolume",
                                       [("InstanceID", "0"), ("DesiredVolume", String(min(max(level, 0), 100)))])
        }
        groupVolumes[group.id] = level
    }

    func volume(of player: SonosPlayer) async -> Int? {
        let response = try? await SonosClient.call(player.host, .renderingControl, "GetVolume",
                                                   [("InstanceID", "0"), ("Channel", "Master")])
        return response?["CurrentVolume"].flatMap { Int($0) }
    }

    func setVolume(_ player: SonosPlayer, _ level: Int) async {
        await run {
            try await SonosClient.call(player.host, .renderingControl, "SetVolume",
                                       [("InstanceID", "0"), ("Channel", "Master"),
                                        ("DesiredVolume", String(min(max(level, 0), 100)))])
        }
    }

    /// מצרף חדר לקבוצה (כמו באפליקציית Sonos)
    func join(_ player: SonosPlayer, to group: SonosGroup) async {
        await run {
            try await SonosClient.call(player.host, .avTransport, "SetAVTransportURI",
                                       [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(group.coordinator.id)"),
                                        ("CurrentURIMetaData", "")])
        }
        await refresh()
    }

    /// מוציא חדר מהקבוצה כך שינגן לבד
    func leave(_ player: SonosPlayer) async {
        await run {
            try await SonosClient.call(player.host, .avTransport, "BecomeCoordinatorOfStandaloneGroup", [("InstanceID", "0")])
        }
        await refresh()
    }

    /// מנגן פריט מ"המועדפים של Sonos" (פלייליסט Spotify / Apple Music, תחנת רדיו…)
    func play(_ favorite: SonosFavorite, in group: SonosGroup) async {
        let host = group.coordinator.host
        let streamPrefixes = ["x-sonosapi-stream:", "x-sonosapi-radio:", "x-rincon-mp3radio:",
                              "x-sonosapi-hls:", "aac:", "hls-radio:"]
        await run {
            if streamPrefixes.contains(where: { favorite.uri.hasPrefix($0) }) {
                try await SonosClient.call(host, .avTransport, "SetAVTransportURI",
                                           [("InstanceID", "0"), ("CurrentURI", favorite.uri),
                                            ("CurrentURIMetaData", favorite.metadata)])
            } else {
                try await SonosClient.call(host, .avTransport, "RemoveAllTracksFromQueue", [("InstanceID", "0")])
                try await SonosClient.call(host, .avTransport, "AddURIToQueue",
                                           [("InstanceID", "0"), ("EnqueuedURI", favorite.uri),
                                            ("EnqueuedURIMetaData", favorite.metadata),
                                            ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0")])
                try await SonosClient.call(host, .avTransport, "SetAVTransportURI",
                                           [("InstanceID", "0"), ("CurrentURI", "x-rincon-queue:\(group.coordinator.id)#0"),
                                            ("CurrentURIMetaData", "")])
            }
            try await SonosClient.call(host, .avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        }
        await updateStatus(of: group)
    }
}
