import SwiftUI
import HomeKit

struct HomeView: View {
    @Environment(HomeStore.self) private var home
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !home.scenes.isEmpty { scenesRow }

                    ForEach(home.rooms, id: \.self) { room in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(room.isEmpty ? "ללא חדר" : room)
                                .font(.title3.bold())
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(home.tiles(in: room)) { tile in
                                    AccessoryTileView(tile: tile)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(home.homeName.isEmpty ? "הבית" : home.homeName)
            .overlay { emptyState }
            .refreshable { home.reload() }
            .alert("משהו השתבש", isPresented: errorBinding) {
                Button("אישור", role: .cancel) {}
            } message: {
                Text(home.lastError ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { home.lastError != nil }, set: { if !$0 { home.lastError = nil } })
    }

    private var scenesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("סצנות").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(home.scenes, id: \.uniqueIdentifier) { scene in
                        Button {
                            Task { await home.run(scene) }
                        } label: {
                            Label(scene.name, systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("הפעלת סצנה")
                    }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if home.status.contains(.determined) && !home.status.contains(.authorized) {
            ContentUnavailableView(
                "אין גישה ל-Apple Home",
                systemImage: "house.slash",
                description: Text("אפשר לאשר גישה בהגדרות ← Songmilim ← בית")
            )
        } else if home.isLoaded && home.tiles.isEmpty {
            ContentUnavailableView(
                "לא נמצאו אביזרים",
                systemImage: "house",
                description: Text("אביזרים שתוסיף באפליקציית 'בית' של אפל יופיעו כאן")
            )
        }
    }
}

struct AccessoryTileView: View {
    @Environment(HomeStore.self) private var home
    let tile: AccessoryTile
    @State private var busy = false

    var body: some View {
        Button {
            Task {
                busy = true
                await home.toggle(tile)
                busy = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: tile.symbol)
                        .font(.title2)
                        .foregroundStyle(tile.isActive ? tile.tint : Color.secondary)
                    Spacer()
                    if busy { ProgressView() }
                }
                Text(tile.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(tile.stateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding()
            .background(
                tile.isActive ? tile.tint.opacity(0.18) : Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .disabled(!tile.isReachable || busy || !tile.isControllable)
        .opacity(tile.isReachable ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityHint(tile.actionHint)
    }
}
