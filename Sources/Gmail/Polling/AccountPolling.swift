import Foundation

/// What AccountManager needs from a per-account poller, whatever the provider.
/// PollingCoordinator (Gmail) and ZohoPollingCoordinator both conform; each
/// account owns one, so a failing account never touches another's state.
@MainActor
protocol AccountPolling: AnyObject {
    var account: AccountState { get }
    var interval: TimeInterval { get set }
    var onTickFinished: (@MainActor () -> Void)? { get set }

    func start() async
    func stop() async
    func popoverOpened() async
    func popoverClosed() async
    func networkChanged(to connection: ConnectionState) async
    func performTick() async
    func markAsRead(_ message: EmailMessage) async
    func clearPersistedState()
}

extension PollingCoordinator: AccountPolling {}
