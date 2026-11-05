import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true

    private var isSigningIn: Bool { model.session == .signingIn }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Sign in to Pandora")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Email", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Toggle("Remember me", isOn: $remember)
            }
            .formStyle(.columns)
            .frame(width: 300)
            .disabled(isSigningIn)
            .onSubmit(signIn)

            HStack {
                if isSigningIn { ProgressView().controlSize(.small) }
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty || isSigningIn)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty, !isSigningIn else { return }
        Task { await model.signIn(username: username, password: password, remember: remember) }
    }
}
