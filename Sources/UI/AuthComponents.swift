import SwiftUI

/// Pieces shared by the sign-in and sign-up screens so the two read as one
/// surface: the Evenings starburst and ET Bembo wordmark, the library-style
/// soft-fill fields, and the primary button that turns brand red once it
/// can be pressed.

/// The Evenings starburst (the website's logo, `sol-logo.svg` in
/// sol-frontend) over the wordmark and a one-line subtitle. The asset is a
/// template so it takes the label colour — white in the dark-only app, the
/// same as it renders on evenings.fm.
struct AuthHeader: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Image("EveningsLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96)
                .foregroundStyle(.primary)
                .accessibilityLabel("Evenings")
                .padding(.bottom, 28)

            Text("Evenings")
                .font(.custom("ETBembo-SemiBoldOSF", size: 48, relativeTo: .largeTitle))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.social(.body))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

/// Matches the library's search field: a faint ink fill, continuous corners.
struct AuthFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.social(.body))
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

/// Brand red with a white label once it can be pressed (the editors'
/// primary-action treatment) or while the request is in flight (spinner).
/// Until then it sits in the fields' neutral fill with a muted label —
/// fading the red instead washes the white label out to near-invisible.
/// Callers still `.disabled(...)` it; this only handles the look.
struct AuthPrimaryButton: View {
    let title: String
    let isActive: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .font(.social(.body, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isActive ? Color.eveningsRed : Color.primary.opacity(0.08))
            .foregroundStyle(isActive ? Color.white : Color(.secondaryLabel))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

/// Brand-red footnote under the fields for validation and server errors.
struct AuthErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.social(.footnote))
            .foregroundStyle(Color.eveningsRed)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// "Already have an account? Log in" — a muted sentence with the action in
/// the primary colour, used to hop between the two auth screens.
struct AuthSwitchLink: View {
    let prompt: String
    let action: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(prompt)
                    .font(.social(.subheadline))
                    .foregroundStyle(.secondary)
                Text(action)
                    .font(.social(.subheadline, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}
