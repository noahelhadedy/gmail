import Foundation

/// Commands another tool (e.g. a Claude session driving Chrome) can send with
/// `open "gmailmenubar://..."`. See HANDOFF.md for the full flow.
enum AutomationCommand: Equatable {
    static let scheme = "gmailmenubar"

    /// `gmailmenubar://add-account?login_hint=<email>` (login_hint optional).
    case addAccount(loginHint: String?)
    /// `gmailmenubar://add-zoho-account?login_hint=<email>` (login_hint optional):
    /// same loopback flow as add-account, but for a Zoho Mail mailbox.
    case addZohoAccount(loginHint: String?)
    /// `gmailmenubar://status`: rewrite accounts-status.json now.
    case status

    /// Returns nil for other schemes and unknown commands.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // Accept both `gmailmenubar://status` and `gmailmenubar:status`.
        let name = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch name {
        case "add-account", "add-zoho-account":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let hint = items.first { $0.name == "login_hint" }?.value?
                .trimmingCharacters(in: .whitespaces)
            let loginHint = (hint?.isEmpty ?? true) ? nil : hint
            self = name == "add-account" ? .addAccount(loginHint: loginHint) : .addZohoAccount(loginHint: loginHint)
        case "status":
            self = .status
        default:
            return nil
        }
    }
}

/// Files under ~/Library/Application Support/Gmail used by the automation path.
/// Neither ever holds a token or the client secret.
enum AutomationFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gmail", isDirectory: true)
    }

    static var pendingAuthURL: URL { directory.appendingPathComponent("pending-auth-url.txt") }
    static var status: URL { directory.appendingPathComponent("accounts-status.json") }

    /// Overwrites `url` with `data`, readable by the owner only (0600).
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
