import Foundation

/// One dispatched server-sent event.
public struct ServerSentEvent: Sendable, Equatable {
    /// The `event:` field, nil when the server didn't send one.
    public var event: String?
    /// All `data:` lines of the event joined with `\n`.
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental `text/event-stream` parser (WHATWG HTML §9.2), fed byte by byte so it
/// doesn't care where the network splits chunks. Handles `\n`, `\r\n` and `\r` line
/// endings, multi-line `data:`, `:` comments, and a leading BOM. `id:` and `retry:`
/// are ignored — Ferry never reconnects a generation.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var afterCR = false
    private var atStart = true
    private var eventType: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one byte; returns an event when this byte completed one.
    public mutating func push(_ byte: UInt8) -> ServerSentEvent? {
        if afterCR {
            afterCR = false
            if byte == 0x0A { return nil } // the LF of a CRLF
        }
        switch byte {
        case 0x0D:
            afterCR = true
            return endLine()
        case 0x0A:
            return endLine()
        default:
            line.append(byte)
            return nil
        }
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        bytes.compactMap { push($0) }
    }

    /// Call at end of stream. Leniently dispatches a final event whose blank line never
    /// arrived (the spec would drop it), so a server that omits it still completes.
    public mutating func finish() -> ServerSentEvent? {
        let pending = line.isEmpty ? nil : endLine()
        return pending ?? dispatch()
    }

    private mutating func endLine() -> ServerSentEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStart {
            atStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        if bytes.isEmpty { return dispatch() }
        if bytes.first == UInt8(ascii: ":") { return nil }

        let text = String(decoding: bytes, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventType = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: eventType, data: dataLines.joined(separator: "\n"))
    }
}
