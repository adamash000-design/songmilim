import SwiftUI
import LocalAuthentication

enum Biometrics {
    /// האם במכשיר מוגדר Face ID / Touch ID / קוד גישה
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Face ID, ואם נכשל – קוד המכשיר. מחזיר true רק אם האימות הצליח.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard isAvailable else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

@MainActor
@Observable
final class AppLock {
    var isEnabled: Bool = UserDefaults.standard.object(forKey: "appLockEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "appLockEnabled") }
    }
    private(set) var isUnlocked = false

    func lock() { isUnlocked = false }

    func unlock() async {
        // אם אין במכשיר שום קוד/Face ID אין במה לנעול
        guard Biometrics.isAvailable else { isUnlocked = true; return }
        isUnlocked = await Biometrics.authenticate(reason: "פתיחת Songmilim")
    }
}

struct LockScreen: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Songmilim נעולה")
                .font(.title.bold())
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("פתח עם Face ID", systemImage: "faceid")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await lock.unlock() }
    }
}
