import Foundation
import SwiftUI

/// Debug-only "screenshot mode". Launch the app with `-screenshot <scene>`
/// (or the env var `EVENINGS_SCREENSHOT=<scene>`) and it renders that scene
/// from fixture data — no network, no Keychain, no microphone — so a
/// simulator (CI or a local Mac) can capture every screen without an account
/// or a live RTMP session:
///
///     xcrun simctl launch booted co.evenings.EveningsBroadcaster -screenshot live
///
/// Inert in Release builds and whenever the argument is absent. Driven by
/// scripts/simulator-screenshots.sh and the "Simulator Screenshots" GitHub
/// Actions workflow (see README → Screenshots).
enum ScreenshotMode {
    enum Scene: String, CaseIterable {
        /// Signed out: the sign-in form.
        case login
        /// Signed out: the account-creation form (pushed over sign-in).
        case signup
        /// Home with the Library tab over the stage.
        case library
        /// Home with the Explore tab (live channels + recent tracks).
        case explore
        /// The account sheet (station photo, name, sign out) over the library.
        case account
        /// The audio editor (trim + tempo) sheet over the library.
        case edit
        /// The audio editor driving itself through a trim, an audition and a
        /// speed change (~15 s) so a simulator *recording* shows it in
        /// motion. Scenes ending in `-demo` are recorded, not screenshotted,
        /// by scripts/simulator-screenshots.sh.
        case editDemo = "edit-demo"
        /// The track detail card (cover, scrubber, transport, share/edit)
        /// floating over the library, on its first track.
        case track
        /// The library opening the detail card by itself: a ghost fingertip
        /// taps the first track's cover, the cover flies into the card over
        /// the frosted library, the card is dismissed, and it plays once
        /// more (~13 s) — the hero transition on record. Recorded, not
        /// screenshotted (see `editDemo`).
        case trackDemo = "track-demo"
        /// The stage revealed, idle (mic check, "Go Live").
        case stage
        /// The stage on air: LIVE badge and elapsed timer.
        case live

        var isSignedIn: Bool { self != .login && self != .signup }
        var showsStage: Bool { self == .stage || self == .live }
        /// The library opens the audio editor on its first track.
        var opensEditor: Bool { self == .edit || self == .editDemo }
        /// The library opens the detail card on its first track.
        var opensDetails: Bool { self == .track }
        /// The editor runs its scripted demo instead of posing from fixtures.
        var animatesEditor: Bool { self == .editDemo }
        /// Home scripts the cover tap → detail card transition itself.
        var animatesDetails: Bool { self == .trackDemo }
    }

    /// The requested scene, parsed once at launch. `-screenshot <scene>` lands
    /// in UserDefaults' argument domain automatically (not persisted).
    static let scene: Scene? = {
        #if DEBUG
        let raw = UserDefaults.standard.string(forKey: "screenshot")
            ?? ProcessInfo.processInfo.environment["EVENINGS_SCREENSHOT"]
        return raw.flatMap { Scene(rawValue: $0.lowercased()) }
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { scene != nil }
}

/// Translucent fingertip, roughly a thumb's contact patch, marking each
/// "touch" in the `-demo` scenes (the editor's and home's scripted demos).
struct DemoFingertip: View {
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.28))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.3), radius: 6)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .allowsHitTesting(false)
    }
}

/// Fixture data for screenshot mode. Fixed dates and no artwork URLs so the
/// captures are deterministic and need no network.
enum ScreenshotFixtures {
    static let station = Station(id: 42, slug: "late-shift", name: "Late Shift", image: nil)

    static let credentials = Credentials(
        accessToken: "screenshot",
        accessTokenExpiresAt: .distantFuture,
        refreshToken: "screenshot",
        streamKey: "screenshot",
        channelId: "screenshot",
        station: station
    )

    /// Reads 02:13 on the stage timer at capture time.
    static let liveSince = Date().addingTimeInterval(-130)

    /// The `edit` scene: a selection with both ends moved, the wheel off
    /// its detent, and the playhead mid-loop, so every readout has a value.
    static let editSelection: ClosedRange<Double> = 0.12...0.78
    static let editRate = 0.92
    static let editPlayhead = 0.41
    /// 56 bars of plausible set dynamics from a fixed-seed LCG — the real
    /// editor decodes these from the stream, which screenshot mode has none of.
    static let editWaveform: [Float] = {
        var seed: UInt32 = 0x2545_F491
        return (0..<56).map { index in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(1 << 24)
            let swell = 0.55 + 0.35 * sin(Double(index) / 56 * .pi * 3)
            return Float(min(1, max(0.12, swell * Double(0.6 + 0.4 * noise))))
        }
    }()

    static let library: [LibraryTrack] = [
        track(101, "Late Shift — Episode 48", streamedAt: "2026-10-02T21:00:00.000Z",
              duration: 2 * 3600 + 14 * 60, listens: 212, tags: ["ambient", "late-night"]),
        track(100, "Late Shift — Episode 47", streamedAt: "2026-09-25T21:00:00.000Z",
              duration: 1 * 3600 + 58 * 60, listens: 340, tags: ["ambient"]),
        track(97, "Rain on the Line (live from the roof)", streamedAt: "2026-09-18T20:30:00.000Z",
              duration: 47 * 60, listens: 88, tags: ["field-recording"]),
        track(95, "Late Shift — Episode 46", streamedAt: "2026-09-11T21:00:00.000Z",
              duration: 2 * 3600 + 3 * 60, listens: 405, tags: ["ambient", "late-night"]),
        track(88, "Tape Loops for Insomniacs", streamedAt: "2026-08-30T23:10:00.000Z",
              duration: 1 * 3600 + 21 * 60, listens: 1_204, tags: ["tape", "drone"],
              owner: false, saved: true, station: otherStation("Night Signal", slug: "night-signal")),
        track(84, "Late Shift — Episode 45", streamedAt: "2026-08-28T21:00:00.000Z",
              duration: 2 * 3600 + 9 * 60, listens: 377, tags: ["ambient"]),
        track(80, "Soundcheck (do not publish)", streamedAt: "2026-08-21T18:45:00.000Z",
              duration: 6 * 60, listens: 0, tags: []),
        track(77, "Late Shift — Episode 44", streamedAt: "2026-08-14T21:00:00.000Z",
              duration: 1 * 3600 + 52 * 60, listens: 298, tags: ["ambient", "late-night"]),
    ]

    static let exploreStreams: [ExploreStream] = [
        ExploreStream(channelId: "ch-morning-static", type: "live", subscribers: 31,
                      name: "Morning Static", title: nil, host: nil, image: nil,
                      station: otherStation("KXRT", slug: "kxrt")),
        ExploreStream(channelId: "ch-dub-hour", type: "live", subscribers: 9,
                      name: "The Dub Hour", title: nil, host: nil, image: nil,
                      station: otherStation("Night Signal", slug: "night-signal")),
    ]

    static let exploreTracks: [LibraryTrack] = [
        track(2_104, "Harbour Lights", streamedAt: "2026-10-03T19:00:00.000Z",
              duration: 1 * 3600 + 5 * 60, listens: 64, tags: ["downtempo"],
              owner: false, station: otherStation("Pier 9", slug: "pier-9")),
        track(2_099, "Tape Loops for Insomniacs", streamedAt: "2026-08-30T23:10:00.000Z",
              duration: 1 * 3600 + 21 * 60, listens: 1_204, tags: ["tape", "drone"],
              owner: false, saved: true, station: otherStation("Night Signal", slug: "night-signal")),
        track(2_092, "Commute Mix 09", streamedAt: "2026-10-01T07:30:00.000Z",
              duration: 42 * 60, listens: 530, tags: ["house", "morning"],
              owner: false, station: otherStation("KXRT", slug: "kxrt")),
        track(2_087, "Late Shift — Episode 48", streamedAt: "2026-10-02T21:00:00.000Z",
              duration: 2 * 3600 + 14 * 60, listens: 212, tags: ["ambient", "late-night"]),
        track(2_080, "Strings & Static", streamedAt: "2026-09-29T22:00:00.000Z",
              duration: 58 * 60, listens: 141, tags: ["modern-classical"],
              owner: false, station: otherStation("Pier 9", slug: "pier-9")),
    ]

    /// Stable ids (never the signed-in station's 42) so "Save to Library"
    /// shows up on other stations' tracks.
    private static func otherStation(_ name: String, slug: String) -> LibraryTrack.TrackStation {
        let id = 1_000 + slug.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return LibraryTrack.TrackStation(id: id, name: name, slug: slug, image: nil)
    }

    private static func track(
        _ id: Int,
        _ title: String,
        streamedAt: String,
        duration: Int,
        listens: Int,
        tags: [String],
        owner: Bool = true,
        saved: Bool? = nil,
        station: LibraryTrack.TrackStation? = nil
    ) -> LibraryTrack {
        LibraryTrack(
            id: id,
            title: title,
            description: nil,
            location: "https://media.evenings.co/fixtures/\(id).m4a",
            image: nil,
            duration: duration,
            tags: tags,
            streamedAt: streamedAt,
            createdAt: streamedAt,
            listens: listens,
            owner: owner,
            saved: saved,
            station: station ?? LibraryTrack.TrackStation(
                id: Self.station.id, name: Self.station.name, slug: Self.station.slug, image: nil
            )
        )
    }
}
