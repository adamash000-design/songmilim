import SwiftUI

struct RoomsView: View {
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("חדרים")
                .navigationDestination(for: String.self) { id in
                    RoomDetailView(coordinatorID: id)
                }
                .toolbar {
                    if !sonos.groups.isEmpty {
                        Button {
                            Task { await sonos.pauseAll() }
                        } label: {
                            Label("עצור הכל", systemImage: "pause.circle")
                        }
                    }
                }
                .task {
                    // רענון חי כל עוד המסך פתוח
                    while !Task.isCancelled {
                        await sonos.refresh()
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if sonos.groups.isEmpty {
            if case .failed(let message) = sonos.state {
                ContentUnavailableView {
                    Label("לא נמצאו רמקולים", systemImage: "hifispeaker.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("נסה שוב") { Task { await sonos.refresh() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("מחפש רמקולי Sonos ברשת…")
            }
        } else {
            List(sonos.groups) { group in
                NavigationLink(value: group.id) {
                    GroupRow(group: group)
                }
            }
        }
    }
}

struct GroupRow: View {
    @Environment(SonosStore.self) private var sonos
    let group: SonosGroup

    var body: some View {
        let info = sonos.nowPlaying[group.id]
        HStack(spacing: 14) {
            CoverArt(url: info?.artURL, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                Text(info?.summary.isEmpty == false ? info!.summary : "שקט")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await sonos.togglePlay(group) }
            } label: {
                Image(systemName: info?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(info?.isPlaying == true ? "השהה ב\(group.name)" : "נגן ב\(group.name)")
        }
        .padding(.vertical, 4)
    }
}

struct RoomDetailView: View {
    @Environment(SonosStore.self) private var sonos
    let coordinatorID: String
    @State private var groupVolume: Double = 0
    @State private var isDraggingVolume = false

    private var group: SonosGroup? {
        sonos.groups.first { $0.id == coordinatorID } ?? sonos.group(containing: coordinatorID)
    }

    var body: some View {
        if let group {
            detail(group)
        } else {
            ContentUnavailableView("החדר לא נמצא", systemImage: "hifispeaker")
        }
    }

    private func detail(_ group: SonosGroup) -> some View {
        let info = sonos.nowPlaying[group.id] ?? NowPlaying()
        return List {
            Section {
                VStack(spacing: 18) {
                    CoverArt(url: info.artURL, size: 220)
                    VStack(spacing: 4) {
                        Text(info.title.isEmpty ? "לא מתנגן כלום" : info.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if !info.artist.isEmpty {
                            Text(info.artist).foregroundStyle(.secondary)
                        }
                    }
                    // פקדי ניגון לא מתהפכים בעברית (כמו באפליקציית המוזיקה של אפל)
                    HStack(spacing: 44) {
                        control("backward.fill", label: "הקודם") { await sonos.previous(group) }
                        control(info.isPlaying ? "pause.fill" : "play.fill",
                                label: info.isPlaying ? "השהה" : "נגן", big: true) { await sonos.togglePlay(group) }
                        control("forward.fill", label: "הבא") { await sonos.next(group) }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $groupVolume, in: 0...100, step: 1, onEditingChanged: { editing in
                            isDraggingVolume = editing
                            if !editing { Task { await sonos.setGroupVolume(group, Int(groupVolume)) } }
                        })
                        .accessibilityLabel("עוצמת קול")
                        .accessibilityValue("\(Int(groupVolume))")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            if group.members.count > 1 {
                Section("עוצמה לכל חדר") {
                    ForEach(group.members) { player in
                        MemberVolumeRow(player: player)
                    }
                }
            }

            Section {
                ForEach(sonos.allPlayers) { player in
                    Toggle(player.name, isOn: Binding(
                        get: { group.members.contains(player) },
                        set: { on in
                            Task {
                                if on { await sonos.join(player, to: group) } else { await sonos.leave(player) }
                            }
                        }
                    ))
                    .disabled(player.id == group.coordinator.id)
                }
            } header: {
                Text("חדרים שמנגנים יחד")
            } footer: {
                Text("הדלק חדר כדי שינגן את אותה מוזיקה.")
            }

            Section {
                if sonos.favorites.isEmpty {
                    Text("אין מועדפים. אפשר להוסיף פלייליסטים ותחנות למועדפים באפליקציית Sonos.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sonos.favorites) { favorite in
                    Button {
                        Task { await sonos.play(favorite, in: group) }
                    } label: {
                        HStack(spacing: 12) {
                            CoverArt(url: favorite.artURL, size: 44)
                            Text(favorite.title).foregroundStyle(.primary)
                        }
                    }
                }
            } header: {
                Text("המועדפים של Sonos")
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { groupVolume = Double(sonos.groupVolumes[group.id] ?? 0) }
        .onChange(of: sonos.groupVolumes[group.id]) { _, newValue in
            if !isDraggingVolume, let newValue { groupVolume = Double(newValue) }
        }
    }

    private func control(_ symbol: String, label: String, big: Bool = false,
                         action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol).font(big ? .system(size: 46) : .title)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

struct MemberVolumeRow: View {
    @Environment(SonosStore.self) private var sonos
    let player: SonosPlayer
    @State private var level: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(player.name).font(.subheadline)
            Slider(value: $level, in: 0...100, step: 1, onEditingChanged: { editing in
                if !editing { Task { await sonos.setVolume(player, Int(level)) } }
            })
            .accessibilityLabel("עוצמה ב\(player.name)")
            .accessibilityValue("\(Int(level))")
        }
        .task { level = Double(await sonos.volume(of: player) ?? 0) }
    }
}
