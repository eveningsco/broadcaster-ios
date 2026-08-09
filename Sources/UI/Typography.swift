import SwiftUI

/// ABC Social, the app's sans-serif (matching the web app), with Dynamic
/// Type scaling anchored to the same text style it replaces. SF Symbols
/// and the monospaced timers stay on the system font.
extension Font {
    enum SocialWeight {
        case regular
        case medium
        case bold

        var postScriptName: String {
            switch self {
            case .regular: return "ABCSocial-Regular"
            case .medium: return "ABCSocial-Medium"
            case .bold: return "ABCSocial-Bold"
            }
        }
    }

    static func social(_ style: Font.TextStyle, weight: SocialWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: Self.baseSize(for: style), relativeTo: style)
    }

    /// Apple's default point sizes per text style (large content size),
    /// so ABC Social drops in at the same optical scale SF Pro had.
    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}
