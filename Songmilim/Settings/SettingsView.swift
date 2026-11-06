import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AppLock.self) private var lock
    @Environment(HomeStore.self) private var home
    @Environment(SonosStore.self) private var sonos
    @Environment(SpotifyService.self) private var spotify
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL

    @State private var manualIP = ""
    @State private var message: String?

    var body: some View {
        @Bindable var lock = lock
        NavigationStack {
            Form {
                Section {
                    Toggle("נעילה ב-Face ID", isOn: $lock.isEnabled)
                } header: {
                    Text("אבטחה")
                } footer: {
                    Text("האפליקציה ננעלת בכל יציאה. פתיחת מנעול דורשת תמיד Face ID, גם כשהנעילה כבויה.")
                }

                Section("Apple Home") {
                    StatusRow(title: home.homeName.isEmpty ? "הבית" : home.homeName,
                              ok: home.status.contains(.authorized),
                              detail: "\(home.tiles.count) אביזרים")
                    if !home.status.contains(.authorized) {
                        Button("פתח הגדרות כדי לאשר גישה") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }

                Section {
                    StatusRow(title: "Sonos", ok: !sonos.groups.isEmpty, detail: "\(sonos.allPlayers.count) חדרים")
                    TextField("כתובת IP של רמקול (לא חובה)", text: $manualIP)
                        .keyboardType(.decimalPad)
                        .environment(\.layoutDirection, .leftToRight)
                    Button("חפש רמקולים מחדש") {
                        guard manualIP.isEmpty || SonosClient.isValidLocalHost(manualIP) else {
                            message = SonosError.invalidHost.localizedDescription
                            return
                        }
                        sonos.manualHost = manualIP
                        Task { await sonos.refresh() }
                    }
                } header: {
                    Text("Sonos")
                } footer: {
                    Text("השליטה ב-Sonos עוברת רק בתוך הרשת הביתית, בלי ענן. אם הרמקולים לא נמצאים אוטומטית, הזן כתובת IP של אחד מהם (מופיעה באפליקציית Sonos ← הגדרות ← מערכת ← אודות).")
                }

                Section("Apple Music") {
                    StatusRow(title: "Apple Music", ok: appleMusic.isAuthorized)
                    if !appleMusic.isAuthorized {
                        Button("אשר גישה ל-Apple Music") { Task { await appleMusic.requestAccess() } }
                    }
                }

                Section {
                    if !spotify.isConfigured {
                        StatusRow(title: "Spotify", ok: false, detail: "חסר Client ID")
                    } else if spotify.isConnected {
                        StatusRow(title: "Spotify", ok: true)
                        Button("התנתק מ-Spotify", role: .destructive) { spotify.disconnect() }
                    } else {
                        StatusRow(title: "Spotify", ok: false)
                        Button("התחבר ל-Spotify") { Task { await connectSpotify() } }
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("ההתחברות נעשית בדף הרשמי של Spotify. הסיסמה שלך לא עוברת דרך האפליקציה.")
                }

                Section {
                    AlexaInfo()
                } header: {
                    Text("Alexa")
                }
            }
            .navigationTitle("חיבורים")
            .onAppear { manualIP = sonos.manualHost }
            .alert("הודעה", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("אישור", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func connectSpotify() async {
        do {
            let url = try spotify.authorizationURL()
            let callback = try await webAuthenticationSession.authenticate(
                using: url,
                callbackURLScheme: SpotifyService.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
            try await spotify.handleCallback(callback)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // המשתמש סגר את החלון – לא שגיאה
        } catch {
            message = error.localizedDescription
        }
    }
}

/// הסבר איך Alexa משתלבת – בלי חיבורים לא רשמיים שפוגעים באבטחה
private struct AlexaInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Alexa ו-Apple Home עובדים יחד דרך Matter", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.bold())
            Text("אם המנעול (או כל אביזר אחר) תומך ב-Matter, אפשר לחבר אותו גם ל-Apple Home וגם ל-Alexa. ככה הוא מופיע כאן וגם Alexa שולטת בו.")
            Text("רמקולי Sonos עם Alexa מובנית, וגם Spotify ו-Apple Music, מתחברים באפליקציית Alexa ← מיומנויות. אחרי זה אפשר לומר \"Alexa, נגן ג׳אז בסלון\".")
            Text("לאמזון אין ממשק רשמי שמאפשר לאפליקציה אחרת לשלוט ב-Alexa. חיבורים לא רשמיים דורשים לשמור את סיסמת אמזון שלך, ולכן לא השתמשנו בהם.")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}
