import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Evenings")
                    .font(.largeTitle.weight(.bold))
                Text("Broadcast from anywhere")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = model.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await model.login(email: email, password: password) }
            } label: {
                Group {
                    if model.isLoggingIn {
                        ProgressView()
                    } else {
                        Text("Log In")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || model.isLoggingIn)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
