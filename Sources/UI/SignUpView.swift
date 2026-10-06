import SwiftUI

/// Account creation — the website's /signup form (email, station name,
/// password, confirmation) in the sign-in screen's clothes. Client-side
/// checks mirror the server's rules (valid email, station name ≥ 4,
/// password ≥ 8) so nobody sees raw validation text; a successful sign-up
/// connects this device immediately and lands on Home like a login would.
struct SignUpView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var stationName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var validationError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case stationName
        case password
        case confirmPassword
    }

    /// Same floors as the API's sign-up validation.
    static let minimumStationNameLength = 4
    static let minimumPasswordLength = 8

    private var allFilled: Bool {
        !email.isEmpty && !stationName.isEmpty && !password.isEmpty && !confirmPassword.isEmpty
    }

    private var canSubmit: Bool {
        allFilled && !model.isSigningUp
    }

    /// Red while pressable or while the request is in flight (spinner).
    private var buttonActive: Bool {
        canSubmit || model.isSigningUp
    }

    /// Local validation wins over a stale server error; typing clears both.
    private var shownError: String? {
        validationError ?? model.signUpError
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AuthHeader(subtitle: "Start your own station")
                    .padding(.top, 32)

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .stationName }
                        .modifier(AuthFieldStyle())

                    TextField("Station name", text: $stationName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .stationName)
                        .onSubmit { focusedField = .password }
                        .modifier(AuthFieldStyle())

                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .password)
                        .onSubmit { focusedField = .confirmPassword }
                        .modifier(AuthFieldStyle())

                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .submitLabel(.join)
                        .focused($focusedField, equals: .confirmPassword)
                        .onSubmit(submit)
                        .modifier(AuthFieldStyle())
                }
                .padding(.top, 40)

                Text("Your station name is how listeners find you. Passwords need at least \(Self.minimumPasswordLength) characters.")
                    .font(.social(.footnote))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                if let error = shownError {
                    AuthErrorText(message: error)
                        .padding(.top, 16)
                }

                AuthPrimaryButton(
                    title: "Create Account",
                    isActive: buttonActive,
                    isBusy: model.isSigningUp,
                    action: submit
                )
                .disabled(!canSubmit)
                .padding(.top, 24)

                AuthSwitchLink(prompt: "Already have an account?", action: "Log in") {
                    focusedField = nil
                    dismiss()
                }
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .onTapGesture { focusedField = nil }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: email) { _ in clearErrors() }
        .onChange(of: stationName) { _ in clearErrors() }
        .onChange(of: password) { _ in clearErrors() }
        .onChange(of: confirmPassword) { _ in clearErrors() }
        .onDisappear { model.signUpError = nil }
    }

    private func clearErrors() {
        validationError = nil
        model.signUpError = nil
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.validate(
            email: trimmedEmail,
            stationName: trimmedName,
            password: password,
            confirmPassword: confirmPassword
        ) {
            validationError = problem
            return
        }
        focusedField = nil
        Task {
            await model.signUp(email: trimmedEmail, stationName: trimmedName, password: password)
        }
    }

    /// The first problem with the form, phrased for the error line, or nil.
    /// Checks run top-to-bottom in field order.
    static func validate(email: String, stationName: String, password: String, confirmPassword: String) -> String? {
        if !isPlausibleEmail(email) {
            return "That doesn't look like an email address."
        }
        if stationName.count < minimumStationNameLength {
            return "Station names need at least \(minimumStationNameLength) characters."
        }
        if password.count < minimumPasswordLength {
            return "Passwords need at least \(minimumPasswordLength) characters."
        }
        if password != confirmPassword {
            return "Passwords do not match. Please try again."
        }
        return nil
    }

    /// Loose shape check (something@something.tld); the server does the
    /// real validation.
    private static func isPlausibleEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}
