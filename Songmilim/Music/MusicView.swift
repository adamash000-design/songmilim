import SwiftUI
import MusicKit

struct MusicView: View {
    enum Source: String, CaseIterable, Identifiable {
        case appleMusic = "Apple Music"
        case spotify = "Spotify"
        var id: String { rawValue }
    }

    @AppStorage("music.source") private var source: Source = .appleMusic
    @State private var query = ""
    @State private var showShazam = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("מקור", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch source {
                case .appleMusic: AppleMusicSection(query: query)
                case .spotify: SpotifySection(query: query)
                }
            }
            .searchable(text: $query, prompt: "שיר, אמן או פלייליסט")
            .navigationTitle("מוזיקה")
            .toolbar {
                Button {
                    showShazam = true
                } label: {
                    Label("זהה שיר", systemImage: "shazam.logo")
                }
            }
            .sheet(isPresented: $showShazam) {
                ShazamSheet { found in query = found }
            }
        }
    }
}

// MARK: - Apple Music

struct AppleMusicSection: View {
    @Environment(AppleMusicService.self) private var appleMusic
    let query: String
    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var errorText: String?

    var body: some View {
        if !appleMusic.isAuthorized {
            ContentUnavailableView {
                Label("Apple Music לא מחובר", systemImage: "music.note")
            } description: {
                Text("צריך לאשר לאפליקציה גישה ל-Apple Music")
            } actions: {
                Button("אשר גישה") { Task { await appleMusic.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    HStack {
                        Text("השמעה ברמקול (AirPlay / Sonos)")
                        Spacer()
                        AirPlayButton()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("בחר רמקול")
                    }
                } footer: {
                    Text("רמקולי Sonos תומכים ב-AirPlay 2 ומופיעים ברשימה.")
                }

                if !playlists.isEmpty {
                    Section(query.isEmpty ? "הפלייליסטים שלי" : "פלייליסטים") {
                        ForEach(playlists) { playlist in
                            Button {
                                play { try await appleMusic.play(playlist) }
                            } label: {
                                appleRow(playlist.name, playlist.curatorName ?? "", playlist.artwork)
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    Section("שירים") {
                        ForEach(songs) { song in
                            Button {
                                play { try await appleMusic.play(song) }
                            } label: {
                                appleRow(song.title, song.artistName, song.artwork)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .task(id: query) { await load() }
        }
    }

    private func appleRow(_ title: String, _ subtitle: String, _ artwork: MusicKit.Artwork?) -> some View {
        HStack(spacing: 12) {
            if let artwork {
                ArtworkImage(artwork, width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
            } else {
                CoverArt(url: nil, size: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        errorText = nil
        do {
            if query.isEmpty {
                songs = []
                playlists = try await appleMusic.libraryPlaylists()
            } else {
                try await Task.sleep(for: .milliseconds(400)) // מחכים שהמשתמש יסיים להקליד
                let result = try await appleMusic.search(query)
                songs = result.songs
                playlists = result.playlists
            }
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func play(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { errorText = error.localizedDescription }
        }
    }
}

// MARK: - Spotify

struct SpotifySection: View {
    @Environment(SpotifyService.self) private var spotify
    let query: String
    @State private var devices: [SpotifyDevice] = []
    @AppStorage("spotify.device") private var selectedDevice = ""
    @State private var tracks: [SpotifyTrack] = []
    @State private var playlists: [SpotifyPlaylist] = []
    @State private var errorText: String?

    var body: some View {
        if !spotify.isConnected {
            ContentUnavailableView(
                "Spotify לא מחובר",
                systemImage: "link",
                description: Text("אפשר להתחבר בלשונית 'חיבורים'")
            )
        } else {
            List {
                Section {
                    Picker("נגן על", selection: $selectedDevice) {
                        Text("בחר רמקול").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    Button("רענן רשימת רמקולים") { Task { await loadDevices() } }
                } footer: {
                    Text("רמקולי Sonos מופיעים כאן דרך Spotify Connect. אם רמקול חסר, נגן עליו פעם אחת מאפליקציית Spotify.")
                }

                if !playlists.isEmpty {
                    Section(query.isEmpty ? "הפלייליסטים שלי" : "פלייליסטים") {
                        ForEach(playlists) { playlist in
                            Button {
                                play(contextURI: playlist.uri)
                            } label: {
                                MediaRow(title: playlist.name, subtitle: playlist.owner?.display_name ?? "",
                                         artURL: playlist.artURL)
                            }
                        }
                    }
                }
                if !tracks.isEmpty {
                    Section("שירים") {
                        ForEach(tracks) { track in
                            Button {
                                play(trackURI: track.uri)
                            } label: {
                                MediaRow(title: track.name, subtitle: track.artistNames, artURL: track.artURL)
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .task { await loadDevices() }
            .task(id: query) { await load() }
        }
    }

    private func loadDevices() async {
        do { devices = try await spotify.devices() } catch { errorText = error.localizedDescription }
    }

    private func load() async {
        errorText = nil
        do {
            if query.isEmpty {
                tracks = []
                playlists = try await spotify.myPlaylists()
            } else {
                try await Task.sleep(for: .milliseconds(400))
                let result = try await spotify.search(query)
                tracks = result.tracks
                playlists = result.playlists
            }
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func play(trackURI: String? = nil, contextURI: String? = nil) {
        guard !selectedDevice.isEmpty else {
            errorText = "בחר קודם רמקול בראש הרשימה"
            return
        }
        Task {
            do {
                errorText = nil
                try await spotify.play(trackURI: trackURI, contextURI: contextURI, on: selectedDevice)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
