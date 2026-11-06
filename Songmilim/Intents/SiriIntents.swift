import AppIntents

// פקודות ל-Siri ולאפליקציית "קיצורים".
// אפשר גם לשלב אותן באוטומציות (למשל: "כשאני מגיע הביתה – נגן בסלון").

struct SonosRoomEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "חדר"
    static var defaultQuery = SonosRoomQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct SonosRoomQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SonosRoomEntity] {
        await Self.allRooms().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SonosRoomEntity] {
        await Self.allRooms()
    }

    @MainActor
    static func allRooms() async -> [SonosRoomEntity] {
        let sonos = SonosStore.shared
        if sonos.groups.isEmpty { await sonos.refresh() }
        return sonos.allPlayers.map { SonosRoomEntity(id: $0.id, name: $0.name) }
    }
}

struct PauseEverywhereIntent: AppIntent {
    static var title: LocalizedStringResource = "עצור את המוזיקה בכל הבית"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Self.run()
        return .result(dialog: "עצרתי את המוזיקה בכל הבית")
    }

    @MainActor
    private static func run() async {
        let sonos = SonosStore.shared
        if sonos.groups.isEmpty { await sonos.refresh() }
        await sonos.pauseAll()
    }
}

struct PlayInRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "המשך לנגן בחדר"

    @Parameter(title: "חדר")
    var room: SonosRoomEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Self.run(roomID: room.id)
        return .result(dialog: "מנגן ב\(room.name)")
    }

    @MainActor
    private static func run(roomID: String) async {
        let sonos = SonosStore.shared
        if sonos.groups.isEmpty { await sonos.refresh() }
        if let group = sonos.group(containing: roomID) { await sonos.play(group) }
    }
}

struct SetRoomVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "קבע עוצמה בחדר"

    @Parameter(title: "חדר")
    var room: SonosRoomEntity

    @Parameter(title: "עוצמה", inclusiveRange: (0, 100))
    var level: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Self.run(roomID: room.id, level: level)
        return .result(dialog: "העוצמה ב\(room.name) היא עכשיו \(level)")
    }

    @MainActor
    private static func run(roomID: String, level: Int) async {
        let sonos = SonosStore.shared
        if sonos.groups.isEmpty { await sonos.refresh() }
        if let player = sonos.allPlayers.first(where: { $0.id == roomID }) {
            await sonos.setVolume(player, level)
        }
    }
}

struct SongmilimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseEverywhereIntent(),
            phrases: ["עצור את המוזיקה ב\(.applicationName)", "\(.applicationName) עצור הכל"],
            shortTitle: "עצור הכל",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: PlayInRoomIntent(),
            phrases: ["נגן בחדר עם \(.applicationName)"],
            shortTitle: "נגן בחדר",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: SetRoomVolumeIntent(),
            phrases: ["קבע עוצמה עם \(.applicationName)"],
            shortTitle: "עוצמה בחדר",
            systemImageName: "speaker.wave.2"
        )
    }
}
