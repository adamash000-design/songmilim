import SwiftUI

@main
struct SongmilimApp: App {
    @State private var home = HomeStore()
    @State private var sonos = SonosStore.shared
    @State private var spotify = SpotifyService.shared
    @State private var appleMusic = AppleMusicService()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(home)
                .environment(sonos)
                .environment(spotify)
                .environment(appleMusic)
                .environment(lock)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .onChange(of: scenePhase) { _, phase in
            // נועלים מחדש בכל פעם שהאפליקציה יוצאת לרקע
            if phase == .background { lock.lock() }
        }
    }
}

struct RootView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            TabView {
                HomeView()
                    .tabItem { Label("בית", systemImage: "house.fill") }
                RoomsView()
                    .tabItem { Label("חדרים", systemImage: "hifispeaker.2.fill") }
                MusicView()
                    .tabItem { Label("מוזיקה", systemImage: "music.note") }
                SettingsView()
                    .tabItem { Label("חיבורים", systemImage: "gearshape.fill") }
            }
            if lock.isEnabled && !lock.isUnlocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: lock.isUnlocked)
    }
}
