import SwiftUI
import UIKit
import WebKit

/// The Instagram sign-in area in Settings: sign in or out, and open the page to clear a checkpoint.
/// The warning text makes clear this account is no longer anonymous and is used only to archive
/// posts and comments. Stories never use it.
struct IGSettingsSection: View {
    @ObservedObject private var creds = IGCredentials.shared
    @State private var signInOpen = false
    @State private var pageOpen = false

    var body: some View {
        Section {
            if let username = creds.username {
                LabeledContent("Signed in as", value: "@\(username)")
                Button("Open Instagram (finish a check or verify)") { pageOpen = true }
                Button("Sign out of Instagram", role: .destructive) { creds.signOut() }
            } else {
                Button("Sign in to Instagram") { signInOpen = true }
            }
        } header: {
            Text("Instagram sign-in")
        } footer: {
            Text(signedOutFooter)
        }
        .sheet(isPresented: $signInOpen) { IGSignInSheet() }
        .sheet(isPresented: $pageOpen) { IGSessionPageSheet() }
    }

    private var signedOutFooter: String {
        if creds.isSignedIn {
            return "Signing in lets NinjaView archive this account's full post history and comments. That account is no longer anonymous while signed in, and it's used only for archiving posts and comments \u{2014} never for stories or highlights. Use a throwaway account: automating a real one can get it rate-limited or flagged. Your password is kept in this iPhone's Keychain."
        }
        return "Without signing in, Instagram shows only an account's newest posts, and stories come from insta-stories-viewer.com. Sign in to archive a full post history with comments. Use a throwaway account, since automating a real one risks it being rate-limited or flagged. The password is stored only in this iPhone's Keychain, and stories never use the sign-in."
    }
}

/// Collects a username and password and stores them (no sign-in attempt here; that happens when
/// archiving runs, so a checkpoint can be handled then).
struct IGSignInSheet: View {
    @ObservedObject private var creds = IGCredentials.shared
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Save") { save() }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                } footer: {
                    Text("Use a throwaway account. NinjaView stores this only in the iPhone's Keychain and signs in to Instagram directly; it isn't sent anywhere else. Stories never use it.")
                }
            }
            .navigationTitle("Instagram sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        if creds.save(username: username, password: password) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } else {
            error = "Couldn't save. Check the username and password and try again."
        }
    }
}

/// Shows the signed-in Instagram page so a person can clear a checkpoint or verification. Reuses
/// the archiver's session page if one is active; otherwise makes a temporary session just to show.
struct IGSessionPageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = SessionHolder()

    var body: some View {
        NavigationStack {
            IGPageContainer(webView: holder.session.bridge.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Instagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .task { await holder.start() }
    }

    @MainActor
    final class SessionHolder: ObservableObject {
        let session: IGSession
        private let ownsSession: Bool
        init() {
            if IGPostArchiver.shared.isRunning {
                session = IGPostArchiver.shared.sharedSession()
                ownsSession = false
            } else {
                session = IGSession()
                ownsSession = true
            }
        }
        func start() async { _ = await session.ensureSignedIn() }
        deinit { if ownsSession { let s = session; Task { @MainActor in s.teardown() } } }
    }
}

/// Hosts a WKWebView in SwiftUI for the checkpoint page.
struct IGPageContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
