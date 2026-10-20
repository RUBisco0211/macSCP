//
//  SettingsView.swift
//  macSCP
//
//  Application settings view (Cmd+, shortcut via Settings scene)
//

import SwiftUI

struct SettingsView: View {
    @State private var appLockManager = AppLockManager.shared
    @State private var languageManager = LanguageManager.shared
    private let biometricService: BiometricAuthServiceProtocol = BiometricAuthService.shared

    private var isBiometricAvailable: Bool {
        biometricService.isBiometricAvailable()
    }

    private var isEnabled: Bool {
        appLockManager.isBiometricLockEnabled
    }

    var body: some View {
        Form {
            languageSection
            securitySection
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Language Section

    @ViewBuilder
    private var languageSection: some View {
        Section {
            Picker(selection: Bindable(languageManager).selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
        } header: {
            Text("Language")
        } footer: {
            if languageManager.needsRestart {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Restart macSCP to apply the language change.")
                    Button("Restart Now") {
                        languageManager.restart()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Security Section

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { appLockManager.isBiometricLockEnabled },
                    set: { newValue in
                        if newValue {
                            appLockManager.enableBiometricLock()
                        } else {
                            Task {
                                await appLockManager.disableBiometricLock()
                            }
                        }
                    }
                )
            ) {
                Label("Require Touch ID", systemImage: "touchid")
            }
            .disabled(!isBiometricAvailable)

            if !isBiometricAvailable {
                Text(
                    "Touch ID is not available on this Mac. Use a Mac with Touch ID or an Apple Watch to enable this feature."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isEnabled {
                Toggle(isOn: Bindable(appLockManager).lockOnAppResume) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lock when switching apps")
                        Text("Require authentication when returning to macSCP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Bindable(appLockManager).lockBeforeConnection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require before each connection")
                        Text("Authenticate before connecting to any server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Toggle(isOn: Bindable(appLockManager).lockAfterInactivity) {
                        Text("Lock after inactivity")
                    }

                    Spacer()

                    Picker("", selection: Bindable(appLockManager).inactivityTimeout) {
                        ForEach(InactivityTimeout.allCases) { timeout in
                            Text(timeout.label).tag(timeout)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!appLockManager.lockAfterInactivity)
                }
            }
        } header: {
            Text("Security")
        } footer: {
            if isEnabled {
                Text("The app always requires authentication on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SettingsView()
}
