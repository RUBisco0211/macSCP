//
//  AppLanguage.swift
//  macSCP
//
//  Languages the app can be displayed in.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follow the macOS preferred language.
    case system

    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Native name for explicit languages; localized name for `.system`.
    var displayName: String {
        switch self {
        case .system:
            return String(localized: "System")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}
