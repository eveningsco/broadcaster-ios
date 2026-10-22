import SwiftUI
import UIKit

/// Debug-only touch indicator for recorded demos that are driven by real
/// taps (UITests/Demos.swift under `simctl recordVideo`): a `DemoFingertip`
/// follows every touch, in its own window above everything the app presents
/// (system menus, sheets, the Files picker), so a viewer sees where each tap
/// lands. Off unless the app is launched in screenshot mode with
/// `-show-touches 1`; release builds compile it out.
///
/// Touches are observed by swizzling `UIWindow.sendEvent(_:)` — the one
/// place every touch in the process passes through, whichever window owns
/// it. The overlay window ignores user interaction, so nothing changes for
/// hit-testing.
@MainActor
final class TouchSpotlight: ObservableObject {
    static let shared = TouchSpotlight()

    struct Spot: Identifiable, Equatable {
        let id: Int
        var point: CGPoint
    }

    @Published private(set) var spots: [Spot] = []

    private var overlay: UIWindow?
    /// Live touches → spot id. UITouch objects are recycled by UIKit, so a
    /// spot gets a fresh id per began-phase rather than per object.
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0

    static var isRequested: Bool {
        #if DEBUG
        return ScreenshotMode.isActive && UserDefaults.standard.bool(forKey: "show-touches")
        #else
        return false
        #endif
    }

    /// Installs the overlay window and the event hook once; safe to call on
    /// every appearance of the root view.
    static func installIfRequested() {
        #if DEBUG
        guard isRequested, shared.overlay == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        _ = UIWindow.spotlightHook
        let window = UIWindow(windowScene: scene)
        // Above alerts and context menus; never key, never interactive.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: SpotlightOverlay(spotlight: shared))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        shared.overlay = window
        #endif
    }

    fileprivate func record(_ touches: Set<UITouch>, in window: UIWindow) {
        guard let overlay else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let point = overlay.convert(touch.location(in: window), from: window)
            switch touch.phase {
            case .began:
                nextID += 1
                ids[key] = nextID
                spots.append(Spot(id: nextID, point: point))
            case .moved, .stationary:
                if let id = ids[key], let index = spots.firstIndex(where: { $0.id == id }) {
                    spots[index].point = point
                }
            case .ended, .cancelled:
                guard let id = ids.removeValue(forKey: key) else { continue }
                // A synthesised tap is down for a few milliseconds; linger so
                // the fingertip survives a 15 fps recording.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.35))
                    spots.removeAll { $0.id == id }
                }
            default:
                continue
            }
        }
    }
}

private struct SpotlightOverlay: View {
    @ObservedObject var spotlight: TouchSpotlight

    var body: some View {
        ZStack {
            ForEach(spotlight.spots) { spot in
                DemoFingertip()
                    .position(spot.point)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: spotlight.spots)
    }
}

#if DEBUG
extension UIWindow {
    /// Swaps `sendEvent(_:)` for `spotlight_sendEvent(_:)` on first access.
    static let spotlightHook: Void = {
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let hook = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.spotlight_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, hook)
    }()

    @objc fileprivate func spotlight_sendEvent(_ event: UIEvent) {
        // Swizzled: this calls the original implementation.
        spotlight_sendEvent(event)
        if event.type == .touches, let touches = event.allTouches {
            TouchSpotlight.shared.record(touches, in: self)
        }
    }
}
#endif
