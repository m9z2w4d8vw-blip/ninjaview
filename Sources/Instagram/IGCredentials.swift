import Foundation
import Security

/// Stores the Instagram sign-in in the iOS Keychain (not UserDefaults), with the username kept
/// separately so the UI can show who's signed in without reading the password back.
@MainActor
final class IGCredentials: ObservableObject {
    static let shared = IGCredentials()

    @Published private(set) var username: String?

    private let service = "com.parv.ninjaview.instagram"
    private let usernameKey = "instagramUsername"

    private init() {
        username = UserDefaults.standard.string(forKey: usernameKey)
    }

    var isSignedIn: Bool { username != nil }

    /// Saves the username and password. Returns false if the Keychain write fails.
    @discardableResult
    func save(username: String, password: String) async -> Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !name.isEmpty, !password.isEmpty else { return false }
        guard store(password, account: name) else {
            DebugLog.shared.error(.store, "Couldn't save the Instagram password to the Keychain")
            return false
        }
        // Switching accounts must invalidate the old site's authenticated cookies as well.
        // Otherwise the archiver could silently read the *previous* Instagram account.
        if let old = self.username, old.lowercased() != name.lowercased() {
            await WebFactory.shared.clearInstagramSession()
            remove(account: old)
        }
        self.username = name
        UserDefaults.standard.set(name, forKey: usernameKey)
        DebugLog.shared.add(.store, "Saved Instagram sign-in for @\(name)")
        return true
    }

    func password() -> String? {
        guard let username else { return nil }
        return read(account: username)
    }

    func signOut() async {
        guard !IGPostArchiver.shared.isRunning else {
            DebugLog.shared.warn(.store, "Stop Instagram archiving before signing out")
            return
        }
        if let username { remove(account: username) }
        username = nil
        UserDefaults.standard.removeObject(forKey: usernameKey)
        // Deleting the Keychain entry alone leaves an authenticated WebKit session behind.
        await WebFactory.shared.clearInstagramSession()
        DebugLog.shared.add(.store, "Signed out of Instagram and cleared its web session")
    }

    // MARK: Keychain

    private func store(_ password: String, account: String) -> Bool {
        let selector: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Updating in place preserves the previous password if the write fails.
        let result = SecItemUpdate(selector as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var add = selector
        add.merge(update) { _, newest in newest }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
