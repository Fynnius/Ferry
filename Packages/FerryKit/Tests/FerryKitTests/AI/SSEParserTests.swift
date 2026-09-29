import Foundation
import Testing
@testable import FerryKit

@Suite("SSE parser")
struct SSEParserTests {
    private let stream = "event: response.created\ndata: {\"a\":1}\n\n: keep-alive comment\n\nevent: response.output_text.delta\ndata: {\"delta\":\"Grüße 👋\"}\n\n"

    private let expected = [
        ServerSentEvent(event: "response.created", data: "{\"a\":1}"),
        ServerSentEvent(event: "response.output_text.delta", data: "{\"delta\":\"Grüße 👋\"}"),
    ]

    @Test func parsesEventsAndSkipsComments() {
        var parser = SSEParser()
        #expect(parser.feed(Array(stream.utf8)) == expected)
        #expect(parser.finish() == nil)
    }

    /// Every possible split point, including inside multi-byte UTF-8 and between CR and LF.
    @Test(arguments: [false, true])
    func chunkBoundariesDontMatter(crlf: Bool) {
        let text = crlf ? stream.replacingOccurrences(of: "\n", with: "\r\n") : stream
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            var parser = SSEParser()
            let events = parser.feed(bytes[..<split]) + parser.feed(bytes[split...])
            #expect(events == expected, "split at \(split)")
        }
    }

    @Test func byteAtATime() {
        var parser = SSEParser()
        let events = stream.utf8.compactMap { parser.push($0) }
        #expect(events == expected)
    }

    @Test func multiLineDataIsJoinedWithNewlines() {
        var parser = SSEParser()
        let events = parser.feed(Array("data: first\ndata:second\ndata\n\n".utf8))
        #expect(events == [ServerSentEvent(event: nil, data: "first\nsecond\n")])
    }

    @Test func bareCarriageReturnsEndLines() {
        var parser = SSEParser()
        #expect(parser.feed(Array("event: x\rdata: y\r\r".utf8)) == [ServerSentEvent(event: "x", data: "y")])
    }

    @Test func eventWithoutDataIsNotDispatchedAndTypeResets() {
        var parser = SSEParser()
        let events = parser.feed(Array("event: ping\n\ndata: z\n\n".utf8))
        #expect(events == [ServerSentEvent(event: nil, data: "z")])
    }

    @Test func leadingBOMIsIgnored() {
        var parser = SSEParser()
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("data: ok\n\n".utf8)
        #expect(parser.feed(bytes) == [ServerSentEvent(data: "ok")])
    }

    @Test func doneSentinelAndUnknownFieldsPassThrough() {
        var parser = SSEParser()
        let events = parser.feed(Array("id: 7\nretry: 100\ndata: [DONE]\n\n".utf8))
        #expect(events == [ServerSentEvent(data: "[DONE]")])
    }

    @Test func finishFlushesAnEventMissingItsBlankLine() {
        var parser = SSEParser()
        #expect(parser.feed(Array("event: response.completed\ndata: {}".utf8)).isEmpty)
        #expect(parser.finish() == ServerSentEvent(event: "response.completed", data: "{}"))
    }
}
