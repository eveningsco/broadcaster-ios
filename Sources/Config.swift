import Foundation

enum Config {
    static let apiBaseURL = URL(string: "https://api.evenings.co")!
    /// RTMP endpoint (app path included); the stream key is appended as the stream name.
    static let rtmpURL = "rtmp://s2.evenings.co/evenings"
    /// Media server base; live streams play from /s/<channelId>.
    static let mediaBaseURL = URL(string: "https://media.evenings.co")!
    static let audioBitrate = 192 * 1000
    static let statusPollInterval: TimeInterval = 5
}
