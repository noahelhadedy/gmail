import Foundation

/// Appends one line per Zoho HTTP reply to `zoho-debug.log` next to the
/// automation files, so a failed sign-in can be diagnosed. Records only the
/// step, HTTP status, content type, size and JSON key names, never values.
enum ZohoDebugLog {
    static var url: URL { AutomationFiles.directory.appendingPathComponent("zoho-debug.log") }

    static func record(step: String, response: URLResponse?, data: Data) {
        let http = response as? HTTPURLResponse
        var line = "\(ISO8601DateFormatter().string(from: Date())) \(step)"
        line += " http=\(http.map { String($0.statusCode) } ?? "none")"
        line += " type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "none")"
        line += " bytes=\(data.count)"
        if let json = try? JSONSerialization.jsonObject(with: data) {
            line += " shape=\(shape(of: json))"
        } else {
            line += " notJSON page=\"\(pageText(data))\""
        }
        append(line + "\n")
    }

    /// Length and character classes of each form field, never the value.
    static func recordFields(step: String, fields: [String: String]) {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let summary = fields.keys.sorted().map { key -> String in
            let value = fields[key]!
            let odd = value.unicodeScalars.filter { !plain.contains($0) }
                .map { String(format: "U+%04X", $0.value) }
            return "\(key):len=\(value.count)\(odd.isEmpty ? "" : " odd=\(Set(odd).sorted())")"
        }
        append("\(ISO8601DateFormatter().string(from: Date())) \(step) fields \(summary.joined(separator: ", "))\n")
    }

    /// Title and first visible words of an HTML error page.
    private static func pageText(_ data: Data) -> String {
        let html = String(decoding: data, as: UTF8.self)
        let noScripts = html.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        let text = noScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(text.prefix(300)).replacingOccurrences(of: "\"", with: "'")
    }

    /// Key names of the top level and of the first `data` entry.
    private static func shape(of json: Any) -> String {
        guard let object = json as? [String: Any] else { return String(describing: type(of: json)) }
        var parts = ["keys=\(object.keys.sorted())"]
        if let status = object["status"] as? [String: Any], let code = status["code"] {
            parts.append("status.code=\(code)")
        }
        if let list = object["data"] as? [[String: Any]] {
            parts.append("data=array(\(list.count)) first=\(list.first.map { $0.keys.sorted() } ?? [])")
        } else if let single = object["data"] as? [String: Any] {
            parts.append("data=object \(single.keys.sorted())")
        }
        return parts.joined(separator: " ")
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        try? FileManager.default.createDirectory(at: AutomationFiles.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
