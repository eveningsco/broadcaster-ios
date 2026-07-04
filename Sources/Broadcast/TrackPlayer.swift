import AVFoundation
import Foundation

/// Minimal playback: streams a track's S3 URL or a channel's live stream with
/// AVPlayer, keyed so the UI knows what's playing.
@MainActor
final class TrackPlayer: ObservableObject {
    @Published private(set) var playingKey: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    static func key(for track: LibraryTrack) -> String { "track-\(track.id)" }
    static func key(for stream: ExploreStream) -> String { "stream-\(stream.channelId)" }

    func toggle(_ track: LibraryTrack) {
        toggle(url: track.audioURL, key: Self.key(for: track))
    }

    func toggle(_ stream: ExploreStream) {
        toggle(url: stream.streamURL, key: Self.key(for: stream))
    }

    private func toggle(url: URL?, key: String) {
        if playingKey == key {
            stop()
            return
        }
        guard let url else { return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player.play()
        self.player = player
        playingKey = key
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        playingKey = nil
    }
}
