import SwiftUI
import UIKit
import WebKit

/// The Instagram sign-in area in Settings: sign in or out, and open the page to clear a checkpoint.
/// The warning text makes clear this account is no longer anonymous and is used only to archive
/// posts and comments. Stories never use it.
struct IGSettingsSection: View {
    @ObservedObject private var creds = IGCredentials.shared
    @ObservedObject private var settings = AppSettings.shared
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
            Toggle("Preview posts without signing in", isOn: $settings.viewerPosts)
        } header: {
            Text("Instagram sign-in")
        } footer: {
            Text(signedOutFooter)
        }
        .sheet(isPresented: $signInOpen) { IGSignInSheet() }
        .sheet(isPresented: $pageOpen) { IGSessionPageSheet() }
    }

    private var signedOutFooter: String {
        let preview = " \u{201C}Preview posts without signing in\u{201D} shows an account's newest posts (about 12) from insta-stories-viewer.com without a sign-in; leave it off to use your signed-in Instagram for posts instead. Stories always come from insta-stories-viewer.com either way."
        if creds.isSignedIn {
            return "Posts are archived from your signed-in Instagram, with full history and comments. That account is no longer anonymous while signed in, and it's used only for posts and comments \u{2014} never for stories or highlights. Use a throwaway account: automating a real one can get it rate-limited or flagged. Your password is kept in this iPhone's Keychain." + preview
        }
        return "Sign in to archive a full post history with comments from Instagram directly. Use a throwaway account, since automating a real one risks it being rate-limited or flagged. The password is stored only in this iPhone's Keychain, and stories never use the sign-in." + preview
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

    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.nvPaper.ignoresSafeArea()
                IGPageContainer(webView: holder.session.bridge.webView)
                    .ignoresSafeArea(edges: .bottom)
                if loading {
                    ProgressView("Opening Instagram")
                        .tint(Color.nvInk)
                }
            }
            .navigationTitle("Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            await holder.session.prepareForDisplay()
            loading = false
        }
        .onDisappear { holder.finish() }
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
        /// Keeps a temporary session parked (not torn down) so a check in progress isn't lost; a
        /// session owned by the archiver is left entirely alone.
        func finish() {
            if ownsSession { session.parkAfterDisplay() }
        }
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
