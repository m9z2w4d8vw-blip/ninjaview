import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            Chrome.apply(appearance)
        }
    }
    @Published var keepHistory: Bool {
        didSet { UserDefaults.standard.set(keepHistory, forKey: Keys.keepHistory) }
    }
    @Published var blockAds: Bool {
        didSet {
            UserDefaults.standard.set(blockAds, forKey: Keys.blockAds)
            WebFactory.shared.settingsChanged()
        }
    }
    @Published var cleanLayout: Bool {
        didSet {
            UserDefaults.standard.set(cleanLayout, forKey: Keys.cleanLayout)
            WebFactory.shared.settingsChanged()
        }
    }

    @Published var prefetch: Bool {
        didSet { UserDefaults.standard.set(prefetch, forKey: Keys.prefetch) }
    }
    @Published var saveComments: Bool {
        didSet { UserDefaults.standard.set(saveComments, forKey: Keys.saveComments) }
    }
    @Published var saveLists: Bool {
        didSet { UserDefaults.standard.set(saveLists, forKey: Keys.saveLists) }
    }

    private enum Keys {
        static let appearance = "appearance"
        static let keepHistory = "keepHistory"
        static let blockAds = "blockAds"
        static let cleanLayout = "cleanLayout"
        static let prefetch = "prefetch"
        static let saveComments = "saveComments"
        static let saveLists = "saveLists"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.keepHistory: true, Keys.blockAds: true, Keys.cleanLayout: true,
                                     Keys.prefetch: true, Keys.saveComments: true, Keys.saveLists: true])
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        keepHistory = defaults.bool(forKey: Keys.keepHistory)
        blockAds = defaults.bool(forKey: Keys.blockAds)
        cleanLayout = defaults.bool(forKey: Keys.cleanLayout)
        prefetch = defaults.bool(forKey: Keys.prefetch)
        saveComments = defaults.bool(forKey: Keys.saveComments)
        saveLists = defaults.bool(forKey: Keys.saveLists)
    }
}
