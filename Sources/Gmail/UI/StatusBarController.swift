import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    let statusItem: NSStatusItem
    let popover: NSPopover

    private let appState: AppState
    private var observationTask: Task<Void, Never>?
    private weak var accountManager: AccountManager?
    private var onOpenSettings: (() -> Void)?
    private var onQuit: (() -> Void)?

    init(appState: AppState, popoverContent: some View) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.contentSize = NSSize(width: 380, height: 480)
        self.popover.behavior = .transient
        self.popover.contentViewController = NSHostingController(rootView: AnyView(popoverContent))

        super.init()
        configureButton()
        self.popover.delegate = self
    }

    func attachAccounts(_ manager: AccountManager) {
        self.accountManager = manager
    }

    func attachContextMenu(onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    func startObserving() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            await self?.observeLoop()
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func observeLoop() async {
        while !Task.isCancelled {
            apply(currentPresentation())
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func currentPresentation() -> StatusBarPresentation {
        StatusBarPresenter.present(
            unreadCount: appState.totalUnreadCount,
            authState: appState.aggregateAuthState,
            connection: appState.connectionState,
            lastError: appState.topPriorityError
        )
    }

    private func apply(_ presentation: StatusBarPresentation) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: "Gmail")
        button.title = presentation.title.isEmpty ? "" : " \(presentation.title)"
        button.imagePosition = .imageLeft
        button.contentTintColor = color(for: presentation.tone)
    }

    private func color(for tone: StatusBarTone) -> NSColor? {
        switch tone {
        case .normal: return nil
        case .auth: return .systemYellow
        case .network: return .systemGray
        case .api: return .systemRed
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            // popoverDidClose handles state — performClose triggers it via the delegate.
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Task { await accountManager?.popoverOpened() }
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: popover.isShown ? "Hide Gmail" : "Open Gmail",
            action: #selector(togglePopoverAction),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Gmail",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePopoverAction() { togglePopover() }
    @objc private func openSettingsAction() { onOpenSettings?() }
    @objc private func quitAction() { onQuit?() }
}

extension StatusBarController: NSPopoverDelegate {
    // .transient popovers auto-close on outside click without going through
    // togglePopover, so we hook the delegate instead — otherwise the polling
    // coordinator stays stuck in .paused(.popoverOpen) and background refresh
    // never resumes.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await self?.accountManager?.popoverClosed()
        }
    }
}
