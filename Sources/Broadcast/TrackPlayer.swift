import AVFoundation
import Foundation

/// Minimal library playback: streams a track's S3 URL with AVPlayer.
@MainActor
final class TrackPlayer: ObservableObject {
    @Published private(set) var playingTrackId: Int?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ track: LibraryTrack) {
        if playingTrackId == track.id {
            stop()
            return
        }
        guard let url = track.audioURL else { return }
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
        playingTrackId = track.id
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        playingTrackId = nil
    }
}
