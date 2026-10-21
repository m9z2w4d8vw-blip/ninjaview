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
    func save(username: String, password: String) -> Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !name.isEmpty, !password.isEmpty else { return false }
        guard store(password, account: name) else {
            DebugLog.shared.error(.store, "Couldn't save the Instagram password to the Keychain")
            return false
        }
        // A different account was signed in before: drop its stored password.
        if let old = username, old.lowercased() != name.lowercased() { remove(account: old) }
        self.username = name
        UserDefaults.standard.set(name, forKey: usernameKey)
        DebugLog.shared.add(.store, "Saved Instagram sign-in for @\(name)")
        return true
    }

    func password() -> String? {
        guard let username else { return nil }
        return read(account: username)
    }

    func signOut() {
        if let username { remove(account: username) }
        username = nil
        UserDefaults.standard.removeObject(forKey: usernameKey)
        DebugLog.shared.add(.store, "Signed out of Instagram")
    }

    // MARK: Keychain

    private func store(_ password: String, account: String) -> Bool {
        remove(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
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
