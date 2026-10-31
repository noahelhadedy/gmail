import Foundation

struct EmailMessage: Identifiable, Equatable, Sendable {
    let id: String
    let threadId: String
    let from: String
    let subject: String
    let internalDate: Date
    let snippet: String?
}

extension EmailMessage {
    /// Gmail "From" header is typically "Name <email@x>"; keep the name only.
    var displayFrom: String {
        if let open = from.firstIndex(of: "<") {
            let name = from[..<open]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
            return String(from[from.index(after: open)...]).trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return from.isEmpty ? "(unknown sender)" : from
    }

    /// Gmail returns snippets HTML-escaped ("&#39;", "&amp;").
    var displaySnippet: String {
        guard let snippet else { return "" }
        // "&amp;" goes last so "&amp;lt;" decodes to "&lt;", not "<".
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&#34;", "\""), ("&nbsp;", " "), ("&amp;", "&")
        ]
        return entities.reduce(snippet) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
