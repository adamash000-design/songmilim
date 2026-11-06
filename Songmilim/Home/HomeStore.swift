import Foundation
import HomeKit
import SwiftUI

struct AccessoryTile: Identifiable {
    enum Kind { case light, outlet, lock, cover, thermostat }

    let id: UUID
    let name: String
    let room: String
    var kind: Kind
    let isReachable: Bool
    var isOn: Bool?
    var isLocked: Bool?
    var position: Int?
    var temperature: Double?
    /// המאפיין שעליו לוחצים (הדלקה / נעילה / מיקום תריס)
    var primary: HMCharacteristic?
}

/// גשר בין ה-delegate-ים של HomeKit (NSObject) ל-Store של SwiftUI
private final class HomeKitBridge: NSObject, HMHomeManagerDelegate, HMAccessoryDelegate {
    let manager = HMHomeManager()
    var onChange: () -> Void = {}

    override init() {
        super.init()
        manager.delegate = self
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { onChange() }
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { onChange() }
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) { onChange() }
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) { onChange() }
}

@MainActor
@Observable
final class HomeStore {
    @ObservationIgnored private let bridge = HomeKitBridge()
    @ObservationIgnored private var subscribed = Set<UUID>()

    private(set) var homeName = ""
    private(set) var tiles: [AccessoryTile] = []
    private(set) var scenes: [HMActionSet] = []
    private(set) var status: HMHomeManagerAuthorizationStatus = []
    private(set) var isLoaded = false
    var lastError: String?

    init() {
        bridge.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    private var home: HMHome? { bridge.manager.homes.first }

    var rooms: [String] { Array(Set(tiles.map(\.room))).sorted() }

    func tiles(in room: String) -> [AccessoryTile] {
        tiles.filter { $0.room == room }
    }

    func reload() {
        status = bridge.manager.authorizationStatus
        guard let home else {
            tiles = []; scenes = []; isLoaded = true
            return
        }
        homeName = home.name
        scenes = home.actionSets
        tiles = home.accessories
            .compactMap(makeTile)
            .sorted { ($0.room, $0.name) < ($1.room, $1.name) }
        isLoaded = true
    }

    private func makeTile(_ accessory: HMAccessory) -> AccessoryTile? {
        accessory.delegate = bridge
        let characteristics = accessory.services.flatMap(\.characteristics)
        func find(_ type: String) -> HMCharacteristic? {
            characteristics.first { $0.characteristicType == type }
        }

        var tile = AccessoryTile(
            id: accessory.uniqueIdentifier,
            name: accessory.name,
            room: accessory.room?.name ?? "",
            kind: .outlet,
            isReachable: accessory.isReachable
        )

        if let target = find(HMCharacteristicTypeTargetLockMechanismState) {
            tile.kind = .lock
            let current = find(HMCharacteristicTypeCurrentLockMechanismState)
            tile.isLocked = ((current?.value ?? target.value) as? Int) == 1
            tile.primary = target
            subscribe(current)
        } else if let target = find(HMCharacteristicTypeTargetPosition) {
            tile.kind = .cover
            let current = find(HMCharacteristicTypeCurrentPosition)
            tile.position = (current?.value ?? target.value) as? Int
            tile.primary = target
            subscribe(current)
        } else if let power = find(HMCharacteristicTypePowerState) {
            let isLight = accessory.services.contains { $0.serviceType == HMServiceTypeLightbulb }
            tile.kind = isLight ? .light : .outlet
            tile.isOn = power.value as? Bool
            tile.primary = power
        } else if let temp = find(HMCharacteristicTypeCurrentTemperature) {
            tile.kind = .thermostat
            tile.temperature = (temp.value as? NSNumber)?.doubleValue
            subscribe(temp)
            return tile
        } else {
            return nil // גשרים וכדומה – לא מציגים
        }

        subscribe(tile.primary)
        return tile
    }

    /// מבקשים עדכונים חיים ממאפיין (פעם אחת לכל מאפיין)
    private func subscribe(_ characteristic: HMCharacteristic?) {
        guard let characteristic, !subscribed.contains(characteristic.uniqueIdentifier) else { return }
        subscribed.insert(characteristic.uniqueIdentifier)
        characteristic.enableNotification(true) { _ in }
        characteristic.readValue { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func toggle(_ tile: AccessoryTile) async {
        guard let characteristic = tile.primary, tile.isReachable else { return }
        do {
            switch tile.kind {
            case .light, .outlet:
                try await characteristic.writeValue(!(tile.isOn ?? false))
            case .lock:
                let unlocking = tile.isLocked == true
                if unlocking {
                    // פתיחת מנעול תמיד דורשת Face ID – גם אם נעילת האפליקציה כבויה
                    guard await Biometrics.authenticate(reason: "פתיחת \(tile.name)") else { return }
                }
                try await characteristic.writeValue(unlocking ? 0 : 1)
            case .cover:
                try await characteristic.writeValue((tile.position ?? 0) > 50 ? 0 : 100)
            case .thermostat:
                return
            }
            try? await characteristic.readValue()
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func run(_ scene: HMActionSet) async {
        guard let home else { return }
        do {
            try await home.executeActionSet(scene)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension AccessoryTile {
    var isControllable: Bool { kind != .thermostat && primary != nil }

    var isActive: Bool {
        switch kind {
        case .light, .outlet: isOn == true
        case .lock: isLocked == false // פתוח = מצב שדורש תשומת לב
        case .cover: (position ?? 0) > 0
        case .thermostat: false
        }
    }

    var symbol: String {
        switch kind {
        case .light: isOn == true ? "lightbulb.fill" : "lightbulb"
        case .outlet: "poweroutlet.type.b.fill"
        case .lock: isLocked == true ? "lock.fill" : "lock.open.fill"
        case .cover: "blinds.horizontal.open"
        case .thermostat: "thermometer.medium"
        }
    }

    var tint: Color {
        switch kind {
        case .light: .yellow
        case .outlet: .green
        case .lock: isLocked == true ? .blue : .orange
        case .cover: .teal
        case .thermostat: .red
        }
    }

    var stateText: String {
        guard isReachable else { return "לא זמין" }
        switch kind {
        case .light, .outlet: return isOn == true ? "דולק" : "כבוי"
        case .lock: return isLocked == true ? "נעול" : "פתוח"
        case .cover: return "פתוח \(position ?? 0)%"
        case .thermostat:
            guard let temperature else { return "—" }
            return "\(Int(temperature.rounded()))°"
        }
    }

    var actionHint: String {
        switch kind {
        case .light, .outlet: isOn == true ? "הקש לכיבוי" : "הקש להדלקה"
        case .lock: isLocked == true ? "הקש לפתיחה, נדרש Face ID" : "הקש לנעילה"
        case .cover: (position ?? 0) > 50 ? "הקש לסגירה" : "הקש לפתיחה"
        case .thermostat: ""
        }
    }
}
