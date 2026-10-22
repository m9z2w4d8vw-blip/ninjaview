import SwiftUI
import UIKit
import WebKit

/// The Instagram sign-in area in Settings: sign in or out, and open the page to clear a checkpoint.
/// The warning text makes clear this account is no longer anonymous and is used only to archive
/// posts and comments. Stories never use it.
struct IGSettingsSection: View {
    @ObservedObject private var creds = IGCredentials.shared
    @ObservedObject private var postArchiver = IGPostArchiver.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var signInOpen = false
    @State private var pageOpen = false

    var body: some View {
        Section {
            if let username = creds.username {
                LabeledContent("Credentials saved for", value: "@\(username)")
                Button("Open Instagram (sign in or verify)") { pageOpen = true }
                Button("Sign out of Instagram", role: .destructive) {
                    Task { await creds.signOut() }
                }
                .disabled(postArchiver.isRunning)
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
            return "Instagram credentials are saved but a successful sign-in has not necessarily been verified. Posts can be archived from a signed-in Instagram session, with full history and comments. That account is no longer anonymous while signed in, and it's used only for posts and comments \u{2014} never for stories or highlights. Use a throwaway account: automating a real one can get it rate-limited or flagged. Your password is kept in this iPhone's Keychain." + preview
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
    @State private var saving = false

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
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                } footer: {
                    Text("Use a throwaway account. Your password is kept in this iPhone's Keychain, then sent to Instagram when signing in. Stories never use the sign-in.")
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

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if await creds.save(username: username, password: password) {
            password = ""
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
    @State private var loadError: String?
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.nvPaper.ignoresSafeArea()
                IGPageContainer(webView: holder.session.bridge.webView)
                    .ignoresSafeArea(edges: .bottom)
                if loading || loadError != nil {
                    VStack(spacing: 16) {
                        if loading {
                            ProgressView("Opening Instagram")
                                .tint(Color.nvInk)
                        } else {
                            Text("Couldn't open Instagram")
                                .font(.headline)
                            Text(loadError ?? "Instagram could not load.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Button("Retry") { loadAttempt += 1 }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nvPaper)
                }
            }
            .navigationTitle("Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: loadAttempt) {
            loading = true
            loadError = nil
            if loadAttempt > 0 { holder.session.reloadForDisplay() }
            let opened = await holder.session.prepareForDisplay()
            guard !Task.isCancelled else { return }
            if !opened {
                switch holder.session.phase {
                case .failed(let why): loadError = why
                default: loadError = "Instagram didn't finish loading. Check your connection and retry."
                }
            }
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
        /// Always reattach the web view to its hidden host when the sheet closes. Otherwise a
        /// running archiver can lose its page when SwiftUI destroys the sheet's view hierarchy.
        func finish() { session.parkAfterDisplay() }
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
