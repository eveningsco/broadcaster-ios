import SwiftUI

/// Sign-in, dressed like the library card it hands off to: the ET Bembo
/// wordmark, ABC Social body text, soft fills for the fields (same as the
/// library's search field), and the brand-red circle and primary button.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !model.isLoggingIn
    }

    /// Red while pressable or while the login is in flight (spinner).
    private var buttonActive: Bool {
        canSubmit || model.isLoggingIn
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // The go-live circle from the home screen doubles as the mark.
            Circle()
                .fill(Color.eveningsRed)
                .frame(width: 56, height: 56)
                .padding(.bottom, 28)

            Text("Evenings")
                .font(.custom("ETBembo-SemiBoldOSF", size: 48, relativeTo: .largeTitle))
                .foregroundStyle(.primary)

            Text("Broadcast from anywhere")
                .font(.social(.body))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .modifier(LoginFieldStyle())

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit(submit)
                    .modifier(LoginFieldStyle())
            }
            .padding(.top, 40)

            if let error = model.loginError {
                Text(error)
                    .font(.social(.footnote))
                    .foregroundStyle(Color.eveningsRed)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }

            // Brand red with a white label once it can be pressed (the
            // editors' primary-action treatment). Until then it sits in the
            // fields' neutral fill with a muted label — fading the red instead
            // washes the white label out to near-invisible.
            Button(action: submit) {
                ZStack {
                    if model.isLoggingIn {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Log In")
                            .font(.social(.body, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(buttonActive ? Color.eveningsRed : Color.primary.opacity(0.08))
                .foregroundStyle(buttonActive ? Color.white : Color(.secondaryLabel))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .animation(.easeInOut(duration: 0.15), value: buttonActive)
            .padding(.top, 24)

            Spacer()
            Spacer()

            Text("evenings.fm")
                .font(.social(.footnote))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await model.login(email: email, password: password) }
    }
}

/// Matches the library's search field: a faint ink fill, continuous corners.
private struct LoginFieldStyle: ViewModifier {
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
