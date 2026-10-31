import SwiftUI

enum PollingInterval: TimeInterval, CaseIterable, Identifiable {
    case sixty = 60
    case oneTwenty = 120
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .sixty: return "60 seconds"
        case .oneTwenty: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        }
    }
}

@MainActor
@Observable
final class SettingsModel {
    var pollingInterval: PollingInterval {
        didSet { defaults.set(pollingInterval.rawValue, forKey: Keys.pollingInterval) }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Keys.pollingInterval) as? TimeInterval
        self.pollingInterval = storedInterval.flatMap(PollingInterval.init(rawValue:)) ?? .sixty
        self.notificationsEnabled = (defaults.object(forKey: Keys.notificationsEnabled) as? Bool) ?? true
        self.launchAtLogin = (defaults.object(forKey: Keys.launchAtLogin) as? Bool) ?? false
    }

    enum Keys {
        static let pollingInterval = "settings.pollingInterval"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let launchAtLogin = "settings.launchAtLogin"
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsModel
    @Bindable var appState: AppState
    let onAddAccount: () -> Void
    let onAddZohoAccount: () -> Void
    let onReauthorize: (String) -> Void
    let onRemoveAccount: (String) -> Void
    let onLaunchAtLoginChanged: (Bool) -> Void
    let onPollingIntervalChanged: (TimeInterval) -> Void

    @State private var pendingRemoval: String?

    var body: some View {
        Form {
            Section {
                if appState.accounts.isEmpty {
                    Text(appState.isConfigured
                         ? "No accounts yet."
                         : "OAuth client ID missing. See SETUP.md.")
                        .foregroundStyle(.secondary)
                }
                ForEach(appState.accounts) { account in
                    accountRow(account)
                }
                Button("Add Account\u{2026}", action: onAddAccount)
                    .disabled(!appState.isConfigured)
                if appState.isZohoConfigured {
                    Button("Add Zoho Account\u{2026}", action: onAddZohoAccount)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Each account signs in separately and is checked on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Polling") {
                Picker("Check for mail every", selection: Binding(
                    get: { settings.pollingInterval },
                    set: { newValue in
                        settings.pollingInterval = newValue
                        onPollingIntervalChanged(newValue.rawValue)
                    }
                )) {
                    ForEach(PollingInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            }
            Section("Notifications") {
                Toggle("Show macOS notifications for new mail", isOn: $settings.notificationsEnabled)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        onLaunchAtLoginChanged(newValue)
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .confirmationDialog(
            "Remove \(pendingRemoval ?? "")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove Account", role: .destructive) {
                if let email = pendingRemoval { onRemoveAccount(email) }
                pendingRemoval = nil
            }
        } message: {
            Text("Its sign-in is revoked and removed from this Mac. Your mail is not touched.")
        }
    }

    private func accountRow(_ account: AccountState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AccountColor.color(for: account.colorIndex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.email)
                    if account.provider != .gmail {
                        Text(account.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if account.needsReauthorization {
                    Label("Needs sign-in", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                } else {
                    Text(account.unreadCount == 1 ? "1 unread" : "\(account.unreadCount) unread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.needsReauthorization {
                Button("Sign In Again") { onReauthorize(account.email) }
                    .disabled(account.provider == .zoho ? !appState.isZohoConfigured : !appState.isConfigured)
            }
            Button {
                pendingRemoval = account.email
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove account")
        }
    }
}
