import Foundation
import SwiftUI

extension Color {
    /// Brand red used for all red text (#FF5C25).
    static let eveningsRed = Color(red: 0xFF / 255, green: 0x5C / 255, blue: 0x25 / 255)
    /// Near-black backdrop of the livestream stage (#151512). Always dark,
    /// regardless of system appearance — content on it renders in dark mode.
    static let eveningsStage = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x12 / 255)
}

enum Config {
    static let apiBaseURL = URL(string: "https://api.evenings.co")!
    /// Public website; track pages live at /<stationSlug>/tracks/<id>.
    static let webBaseURL = URL(string: "https://evenings.fm")!
    /// RTMP endpoint (app path included); the stream key is appended as the stream name.
    static let rtmpURL = "rtmp://s2.evenings.co/evenings"
    /// Media server base; live streams play from /s/<channelId>.
    static let mediaBaseURL = URL(string: "https://media.evenings.co")!
    static let audioBitrate = 192 * 1000
}
