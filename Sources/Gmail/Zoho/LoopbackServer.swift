import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that catches Zoho's OAuth redirect and
/// hands back the query items. Zoho needs the redirect URI registered exactly,
/// so the port is fixed (see SETUP-ZOHO.md) instead of random like Google's.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gmail.zoho.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?
    private var outcome: Result<[URLQueryItem], Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw AppError.auth(.authorizationFailed(reason: "invalid loopback port"))
        }
        listener = try NWListener(using: parameters, on: endpointPort)
    }

    /// Binds the port. Throws if it is taken (another sign-in still running).
    func start() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() { ready.resume() }
                case .failed(let error):
                    if resumed.setOnce() { ready.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Suspends until the browser is redirected back, `cancel()` or a timeout.
    func waitForCallback() async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel(reason: String = "cancelled") {
        finish(.failure(AppError.auth(.authorizationFailed(reason: reason))))
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        listener.cancel()
        pending?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let items = data.flatMap { Self.queryItems(fromRequest: $0) }
            let isCallback = items?.contains { $0.name == "code" || $0.name == "error" } == true
            let body = isCallback
                ? "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>Signed in</h2><p>You can close this tab and go back to Gmail.</p></body></html>"
                : "Not found"
            let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if isCallback, let items { self.finish(.success(items)) }
        }
    }

    /// Reads `GET /?code=...&state=... HTTP/1.1` and returns the query items.
    static func queryItems(fromRequest data: Data) -> [URLQueryItem]? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        return components.queryItems ?? []
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func setOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
