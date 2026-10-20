//
//  LanguageManager.swift
//  macSCP
//
//  Persists the user's language choice and applies it through AppleLanguages.
//

import AppKit
import Observation

/// macOS resolves an app's localization at launch, so a language change takes
/// effect after a restart. `needsRestart` drives the restart prompt in Settings.
@MainActor
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private enum Keys {
        static let selectedLanguage = "com.macSCP.appLanguage"
        static let appleLanguages = "AppleLanguages"
    }

    var selectedLanguage: AppLanguage {
        didSet {
            guard selectedLanguage != oldValue else { return }
            apply(selectedLanguage)
            needsRestart = true
        }
    }

    private(set) var needsRestart = false

    private init() {
        let stored = UserDefaults.standard.string(forKey: Keys.selectedLanguage)
        // No stored value means first launch: follow the system language.
        selectedLanguage = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func apply(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: Keys.selectedLanguage)
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: Keys.appleLanguages)
        case .english:
            UserDefaults.standard.set(["en"], forKey: Keys.appleLanguages)
        case .simplifiedChinese:
            UserDefaults.standard.set(["zh-Hans"], forKey: Keys.appleLanguages)
        }
        // The app may restart immediately after the choice, so flush the preference.
        UserDefaults.standard.synchronize()
    }
}
