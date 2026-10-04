import SwiftUI

/// Sign-in, dressed like the library card it hands off to: the ET Bembo
/// wordmark, ABC Social body text, soft fills for the fields (same as the
/// library's search field), and the Evenings logo and primary button.
/// Shares its chrome with SignUpView via AuthComponents; "Create an account"
/// pushes that screen onto the stack.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    /// Screenshot mode's `signup` scene opens straight onto the sign-up form.
    @State private var showingSignUp = ScreenshotMode.scene == .signup
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
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                AuthHeader(subtitle: "Broadcast from anywhere")

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                        .modifier(AuthFieldStyle())

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit(submit)
                        .modifier(AuthFieldStyle())
                }
                .padding(.top, 40)

                if let error = model.loginError {
                    AuthErrorText(message: error)
                        .padding(.top, 16)
                }

                AuthPrimaryButton(
                    title: "Log In",
                    isActive: buttonActive,
                    isBusy: model.isLoggingIn,
                    action: submit
                )
                .disabled(!canSubmit)
                .padding(.top, 24)

                AuthSwitchLink(prompt: "New to Evenings?", action: "Create an account") {
                    focusedField = nil
                    showingSignUp = true
                }
                .padding(.top, 20)

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
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingSignUp) {
                SignUpView()
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await model.login(email: email, password: password) }
    }
}
