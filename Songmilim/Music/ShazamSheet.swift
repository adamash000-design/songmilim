import SwiftUI
import ShazamKit

@MainActor
@Observable
final class ShazamService {
    enum Phase {
        case idle, listening, notFound
        case found(title: String, artist: String, artwork: URL?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var session: SHManagedSession?

    func identify() async {
        phase = .listening
        let session = SHManagedSession()
        self.session = session
        let result = await session.result()
        switch result {
        case .match(let match):
            let item = match.mediaItems.first
            phase = .found(title: item?.title ?? "", artist: item?.artist ?? "", artwork: item?.artworkURL)
        case .noMatch:
            phase = .notFound
        case .error(let error, _):
            phase = .failed(error.localizedDescription)
        }
        self.session = nil
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

/// "מה השיר הזה?" – מזהה שיר שמתנגן בחדר ומאפשר לחפש אותו
struct ShazamSheet: View {
    var onSearch: (String) -> Void
    @State private var shazam = ShazamService()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch shazam.phase {
                case .idle, .listening:
                    Image(systemName: "shazam.logo.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse)
                    Text("מקשיב…").font(.title3)
                case .found(let title, let artist, let artwork):
                    CoverArt(url: artwork, size: 180)
                    VStack(spacing: 4) {
                        Text(title).font(.title2.bold())
                        Text(artist).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    Button("חפש את השיר") {
                        onSearch("\(title) \(artist)")
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                case .notFound:
                    ContentUnavailableView("לא זיהיתי את השיר", systemImage: "questionmark.circle")
                    Button("נסה שוב") { Task { await shazam.identify() } }
                case .failed(let message):
                    ContentUnavailableView("הזיהוי נכשל", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("זיהוי שיר")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגור") { shazam.cancel(); dismiss() }
                }
            }
            .task { await shazam.identify() }
        }
        .presentationDetents([.medium, .large])
    }
}
