import Foundation

/// Client-side safety net for models that ignore "no fences, no quotes".
/// Never shortens the message itself: a cut-off subject looks broken.
public enum CommitMessageCleanup {
    /// For text still streaming: hides an opening code fence (and its language tag) so
    /// the field doesn't flash ```` ```text ````. Returns "" while the fence line is incomplete.
    public static func partial(_ text: String) -> String {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix("`") else { return String(trimmed) }
        if "```".hasPrefix(trimmed) { return "" }
        guard trimmed.hasPrefix("```") else { return String(trimmed) }
        guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
        var body = String(trimmed[trimmed.index(after: newline)...])
        // Hide a closing fence that's arriving on the last line.
        if let newline = body.lastIndex(of: "\n") {
            let lastLine = body[body.index(after: newline)...]
            if !lastLine.isEmpty, "```".hasPrefix(lastLine) { body = String(body[..<newline]) }
        }
        return body
    }

    /// For the finished message: strips a wrapping code fence, then wrapping quotes, then whitespace.
    public static func final(_ text: String) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("```") {
            if let newline = message.firstIndex(of: "\n") {
                message = String(message[message.index(after: newline)...])
            } else {
                message = String(message.dropFirst(3))
            }
            message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasSuffix("```") { message = String(message.dropLast(3)) }
            message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("“", "”"), ("‘", "’")]
        for (open, close) in pairs where message.count >= 2 && message.first == open && message.last == close {
            message = String(message.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return message
    }
}
