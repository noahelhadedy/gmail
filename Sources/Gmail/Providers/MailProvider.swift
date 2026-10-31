import Foundation

/// Which mail service an account lives on. Gmail behavior is the default for
/// everything stored before Zoho support existed.
enum MailProvider: String, Codable, Equatable, Sendable {
    case gmail
    case zoho

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .zoho: return "Zoho Mail"
        }
    }
}

/// Zoho keeps every account in one regional data center; the API, OAuth and web
/// hosts all follow the same suffix (zoho.com, zoho.eu, zoho.in ...).
/// designbookmark.com has MX records at mx.zoho.com, so it lives in `.com`.
enum ZohoDataCenter: String, Codable, CaseIterable, Equatable, Sendable {
    case com
    case eu
    case `in`
    case comAu = "com.au"
    case jp
    case ca
    case sa
    case comCn = "com.cn"

    var accountsHost: String { "accounts.zoho.\(rawValue)" }
    var mailHost: String { "mail.zoho.\(rawValue)" }

    /// Maps Zoho's `location` redirect parameter ("us", "eu", "in", "au", ...)
    /// or an `accounts-server` URL to a data center.
    static func from(location: String?, accountsServer: String?) -> ZohoDataCenter? {
        if let host = accountsServer.flatMap({ URL(string: $0)?.host }),
           let match = allCases.first(where: { $0.accountsHost == host.lowercased() }) {
            return match
        }
        switch location?.lowercased() {
        case "us", "com": return .com
        case "eu": return .eu
        case "in": return .in
        case "au", "com.au": return .comAu
        case "jp": return .jp
        case "ca": return .ca
        case "sa": return .sa
        case "cn", "com.cn": return .comCn
        default: return nil
        }
    }
}

/// Web URLs that open Zoho Mail in the browser.
enum ZohoWebURL {
    static func inbox(dataCenter: ZohoDataCenter) -> URL {
        URL(string: "https://\(dataCenter.mailHost)/zm/#mail/folder/inbox")!
    }

    static func message(dataCenter: ZohoDataCenter, messageId: String) -> URL {
        URL(string: "https://\(dataCenter.mailHost)/zm/#mail/folder/inbox/p/\(messageId)")!
    }
}
