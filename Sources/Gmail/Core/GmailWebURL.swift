import Foundation

/// Builds Gmail web URLs that open in a specific Google account.
///
/// The path-based form `/mail/u/{email}/` was historically supported but
/// regularly fails today with "account temporarily unavailable". The
/// reliable disambiguator is the `?authuser={email}` query parameter,
/// which Google's own products (Calendar → email) use.
enum GmailWebURL {
    /// Opens the conversation view, which is keyed on thread, not individual message.
    static func thread(email: String, threadId: String) -> URL {
        make(email: email, fragment: "inbox/\(threadId)")
    }

    static func inbox(email: String) -> URL {
        make(email: email, fragment: "inbox")
    }

    private static func make(email: String, fragment: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "mail.google.com"
        components.path = "/mail/"
        if !email.isEmpty {
            // URLComponents leaves "+" alone in queries, and Google decodes a bare
            // "+" as a space, so plus-addressed emails need it escaped by hand.
            let encoded = email
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "+", with: "%2B") ?? email
            components.percentEncodedQuery = "authuser=\(encoded)"
        }
        components.fragment = fragment
        return components.url!
    }
}
