import Foundation
import MusicKit

/// Apple Music דרך MusicKit של אפל – ההרשאה מנוהלת ע"י iOS, אין צורך בסיסמה או מפתח.
@MainActor
@Observable
final class AppleMusicService {
    private(set) var status: MusicAuthorization.Status = MusicAuthorization.currentStatus

    var isAuthorized: Bool { status == .authorized }

    func requestAccess() async {
        status = await MusicAuthorization.request()
    }

    func search(_ term: String) async throws -> (songs: [Song], playlists: [Playlist]) {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Playlist.self])
        request.limit = 15
        let response = try await request.response()
        return (Array(response.songs), Array(response.playlists))
    }

    func libraryPlaylists() async throws -> [Playlist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 50
        return Array(try await request.response().items)
    }

    func play(_ song: Song) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.play()
    }

    func play(_ playlist: Playlist) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
        try await player.play()
    }
}
