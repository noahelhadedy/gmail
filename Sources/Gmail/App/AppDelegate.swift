import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()

    private var accounts: AccountManager!
    private var notificationManager: NotificationManager!
    private var statusBar: StatusBarController!
    private var networkMonitor: NetworkMonitor!
    private var networkTask: Task<Void, Never>?
    private var settingsModel: SettingsModel!
    private var settingsWindow: NSWindowController?
    private let loginItems = LoginItemsManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsModel = SettingsModel()
        notificationManager = NotificationManager(isEnabled: {
            (UserDefaults.standard.object(forKey: SettingsModel.Keys.notificationsEnabled) as? Bool) ?? true
        })

        // Without a client ID the app still runs (accounts list, settings, setup
        // help) so it can be launched and checked before Google Cloud is set up.
        accounts = AccountManager(
            appState: appState,
            store: AccountStore(),
            keychain: KeychainService(),
            authorizer: Self.makeAuthorizer(),
            api: GmailAPIClient(),
            notifier: notificationManager
        )
        accounts.interval = settingsModel.pollingInterval.rawValue

        let popoverContent = PopoverView(
            appState: appState,
            onRefresh: { [weak self] in Task { await self?.accounts.refreshAll() } },
            onRefreshAccount: { [weak self] email in Task { await self?.accounts.refresh(email: email) } },
            onAddAccount: { [weak self] in Task { await self?.addAccount() } },
            onReauthorize: { [weak self] _ in Task { await self?.addAccount() } },
            onMarkAsRead: { [weak self] message, email in
                Task { await self?.accounts.markAsRead(message, in: email) }
            },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        statusBar = StatusBarController(appState: appState, popoverContent: popoverContent)
        statusBar.attachAccounts(accounts)
        statusBar.attachContextMenu(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        statusBar.startObserving()

        networkMonitor = NetworkMonitor()
        startNetworkObservation()

        UNUserNotificationCenter.current().delegate = self
        Task { await notificationManager.requestAuthorization() }

        if DemoData.isEnabled {
            DemoData.populate(appState)
            return
        }
        Task { await accounts.restoreAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reads the OAuth client baked into Info.plist by scripts/build.sh.
    /// Returns nil when the build is unconfigured (placeholders still present).
    private static func makeAuthorizer() -> AppAuthAuthorizer? {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "OAuthClientID") as? String,
              let scheme = Bundle.main.object(forInfoDictionaryKey: "OAuthRedirectURLScheme") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"),
              !scheme.contains("__OAUTH"), !scheme.contains("YOUR_REVERSED") else {
            return nil
        }
        let clientSecretRaw = Bundle.main.object(forInfoDictionaryKey: "OAuthClientSecret") as? String
        let clientSecret = (clientSecretRaw?.isEmpty == false && clientSecretRaw != "__OAUTH_CLIENT_SECRET__")
            ? clientSecretRaw : nil
        return AppAuthAuthorizer(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURL: URL(string: "\(scheme):/oauth2redirect")!
        )
    }

    private func startNetworkObservation() {
        networkTask?.cancel()
        networkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.networkMonitor.start()
            for await state in await self.networkMonitor.stateStream {
                await self.accounts.networkChanged(to: state)
            }
        }
    }

    /// Used for both "Add Account" and "Sign In Again": Google's account picker
    /// decides which account comes back, and AccountManager matches it by email.
    private func addAccount() async {
        guard appState.isConfigured else {
            presentMissingClientIDAlert()
            return
        }
        do {
            try await accounts.addAccount()
        } catch {
            // Closing the browser sheet is a normal cancel; stay quiet about it.
            let nsError = error as NSError
            if nsError.domain == "org.openid.appauth.general", nsError.code == -3 { return }
            presentError("Couldn't add the account", detail: error.localizedDescription)
        }
    }

    private func removeAccount(_ email: String) async {
        await accounts.removeAccount(email: email)
    }

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settingsModel,
                appState: appState,
                onAddAccount: { [weak self] in Task { await self?.addAccount() } },
                onReauthorize: { [weak self] _ in Task { await self?.addAccount() } },
                onRemoveAccount: { [weak self] email in Task { await self?.removeAccount(email) } },
                onLaunchAtLoginChanged: { [weak self] enabled in
                    self?.loginItems.setEnabled(enabled)
                },
                onPollingIntervalChanged: { [weak self] interval in
                    self?.accounts.interval = interval
                }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Gmail Settings"
            window.styleMask = [.titled, .closable]
            settingsWindow = NSWindowController(window: window)
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentMissingClientIDAlert() {
        presentError(
            "OAuth client ID missing",
            detail: "Create a Google Cloud Desktop OAuth client, then rebuild with scripts/build.sh. See SETUP.md."
        )
    }

    private func presentError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
