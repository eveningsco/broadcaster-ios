import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Minimal playback: streams a track's S3 URL with AVPlayer, keyed so the UI
/// knows what's playing. Publishes Now Playing info so the lock screen and
/// Control Center show the track with play/pause and scrubbing.
@MainActor
final class TrackPlayer: ObservableObject {
    @Published private(set) var playingKey: String?
    /// Playback position as a 0...1 fraction of the track's duration.
    @Published private(set) var progress: Double = 0
    /// Seeks in flight. AVPlayer seeks are async, and until one lands the
    /// periodic observer still reports the old position — publishing those
    /// stale ticks yanks the needle back right after a scrub release.
    private var pendingSeeks = 0
    /// True while the loaded track is paused (still loaded, not stopped).
    @Published private(set) var isPaused = false
    /// Key of the track that loops when it ends. Looping is per-track:
    /// selecting a different track leaves it behind.
    @Published private(set) var loopingKey: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var trackTitle: String?
    private var trackArtist: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    /// The item's duration isn't known until metadata loads; republish the
    /// Now Playing info once so the lock screen scrubber gets a length.
    private var durationPublished = false

    init() {
        configureRemoteCommands()
    }

    static func key(for track: LibraryTrack) -> String { "track-\(track.id)" }
    static func key(for stream: ExploreStream) -> String { "stream-\(stream.channelId)" }

    func toggle(_ stream: ExploreStream) {
        toggle(
            url: stream.streamURL,
            key: Self.key(for: stream),
            title: stream.displayName,
            artist: stream.station?.name,
            artworkURL: (stream.image ?? stream.station?.image).flatMap(URL.init(string:))
        )
    }

    func toggle(_ track: LibraryTrack) {
        toggle(
            url: track.audioURL,
            key: Self.key(for: track),
            title: track.title ?? "Untitled",
            artist: track.station?.name,
            artworkURL: (track.image ?? track.station?.image).flatMap(URL.init(string:))
        )
    }

    func toggle(
        url: URL?,
        key: String,
        title: String? = nil,
        artist: String? = nil,
        artworkURL: URL? = nil
    ) {
        // Re-selecting the loaded track toggles pause instead of stopping.
        if playingKey == key {
            if isPaused { resume() } else { pause() }
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
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
        player.play()
        self.player = player
        playingKey = key
        progress = 0
        pendingSeeks = 0
        isPaused = false
        trackTitle = title
        trackArtist = artist
        durationPublished = false
        applyLoopingBehavior()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.updateProgress(currentTime: time.seconds) }
        }
        publishNowPlaying()
        loadArtwork(from: artworkURL)
    }

    /// Whether the currently loaded track is set to loop.
    var isLoopingCurrent: Bool {
        loopingKey != nil && loopingKey == playingKey
    }

    /// Toggles looping for the currently loaded track; no-op with nothing
    /// loaded.
    func toggleLooping() {
        guard let playingKey else { return }
        loopingKey = isLoopingCurrent ? nil : playingKey
        applyLoopingBehavior()
    }

    /// While looping, the player must not halt at the item's end — it rolls
    /// through the boundary and the end notification just rewinds it. Pausing
    /// at the end (and the restart race it causes) is what broke looping.
    private func applyLoopingBehavior() {
        player?.actionAtItemEnd = isLoopingCurrent ? .none : .pause
    }

    func pause() {
        guard playingKey != nil else { return }
        player?.pause()
        isPaused = true
        publishNowPlaying()
    }

    func resume() {
        guard playingKey != nil, let player else { return }
        // Replaying from the end: rewind first.
        if progress >= 0.999 {
            pendingSeeks += 1
            player.seek(to: .zero) { [weak self] _ in
                Task { @MainActor in self?.pendingSeeks -= 1 }
            }
            progress = 0
        }
        // Mic monitoring may have owned the session in between; take it back.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPaused = false
        publishNowPlaying()
    }

    /// Jumps to the given 0...1 position. No-op while the duration is still
    /// unknown (stream metadata not loaded yet).
    func seek(toFraction fraction: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        progress = clamped
        pendingSeeks += 1
        player.seek(
            to: CMTime(seconds: duration * clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in self?.pendingSeeks -= 1 }
        }
        publishNowPlaying()
    }

    func seek(toSeconds seconds: Double) {
        guard let duration = player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        seek(toFraction: seconds / duration)
    }

    private func updateProgress(currentTime: Double) {
        // Stale ticks while a seek is settling would drag the needle back.
        guard pendingSeeks == 0 else { return }
        guard let duration = player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        progress = min(max(currentTime / duration, 0), 1)
        if !durationPublished {
            durationPublished = true
            publishNowPlaying()
        }
    }

    /// The track ran out: loop from the top if this track is set to loop,
    /// otherwise stay loaded and paused at the end so the player stays open.
    private func handlePlaybackEnded() {
        if isLoopingCurrent, let player {
            // actionAtItemEnd is .none, so the player is still rolling —
            // rewinding is all it takes.
            pendingSeeks += 1
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.pendingSeeks -= 1 }
            }
            progress = 0
            isPaused = false
        } else {
            player?.pause()
            isPaused = true
            progress = 1
        }
        publishNowPlaying()
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        playingKey = nil
        progress = 0
        pendingSeeks = 0
        isPaused = false
        trackTitle = nil
        trackArtist = nil
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Now Playing

    private func publishNowPlaying() {
        guard playingKey != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: trackTitle ?? "Untitled",
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime().seconds ?? 0,
        ]
        if let trackArtist {
            info[MPMediaItemPropertyArtist] = trackArtist
        }
        if let duration = player?.currentItem?.duration.seconds,
           duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let self, !Task.isCancelled else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publishNowPlaying()
        }
    }

    /// Lock screen / Control Center / headphone controls.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPaused { self.resume() } else { self.pause() }
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(toSeconds: position) }
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
