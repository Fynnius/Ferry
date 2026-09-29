import Foundation
import Synchronization
import Testing
@testable import FerryKit

/// Canned HTTP responses; never touches the network.
private final class MockTransport: CommitMessageTransport {
    let status: Int
    let headers: [String: String]
    let body: Data
    let failure: (any Error)?
    let requests = Mutex<[URLRequest]>([])

    init(status: Int = 200, headers: [String: String] = [:], body: String = "", failure: (any Error)? = nil) {
        self.status = status
        self.headers = headers
        self.body = Data(body.utf8)
        self.failure = failure
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<UInt8, any Error>) {
        requests.withLock { $0.append(request) }
        if let failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let body = self.body
        return (response, AsyncThrowingStream { continuation in
            for byte in body { continuation.yield(byte) }
            continuation.finish()
        })
    }
}

/// Sends a few deltas, then never finishes — like a slow model — and records when the
/// body stream is torn down.
private final class HangingTransport: CommitMessageTransport {
    let sent = Mutex(false)
    let terminated = Mutex(false)

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<UInt8, any Error>) {
        sent.withLock { $0 = true }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, AsyncThrowingStream { continuation in
            for byte in Data(SSE.delta("Add").utf8) { continuation.yield(byte) }
            continuation.onTermination = { [self] _ in terminated.withLock { $0 = true } }
        })
    }
}

enum SSE {
    static func event(_ type: String, _ payload: [String: Any]) -> String {
        var payload = payload
        payload["type"] = type
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "event: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
    }

    static func delta(_ text: String) -> String {
        event("response.output_text.delta", ["delta": text, "item_id": "msg_1", "output_index": 0, "content_index": 0])
    }

    static let completed = event("response.completed", ["response": ["id": "resp_1", "status": "completed"]])

    static func stream(_ deltas: [String], end: String = completed) -> String {
        event("response.created", ["response": ["id": "resp_1"]]) + deltas.map(delta).joined() + end
    }
}

private let prompt = CommitPrompt(system: "SYSTEM", user: "USER")

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within 2s")
}

private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}

@Suite("Commit message generator")
struct CommitMessageGeneratorTests {
    // MARK: Request

    @Test func requestBodyMatchesTheContract() throws {
        let generator = CommitMessageGenerator(transport: MockTransport())
        let request = try generator.makeRequest(prompt, apiKey: "  sk-test\n")

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "input", "reasoning", "text", "max_output_tokens", "stream", "store"])
        #expect(json["model"] as? String == "gpt-6-luna")
        #expect(json["stream"] as? Bool == true)
        #expect(json["store"] as? Bool == false)
        #expect(json["max_output_tokens"] as? Int == 300)
        #expect(json["reasoning"] as? [String: String] == ["effort": "none"])
        #expect(json["text"] as? [String: String] == ["verbosity": "low"])
        let input = try #require(json["input"] as? [[String: String]])
        #expect(input == [["role": "system", "content": "SYSTEM"], ["role": "user", "content": "USER"]])
    }

    @Test func configurationOverridesModelEndpointAndOmitsReasoning() throws {
        let configuration = CommitMessageGenerator.Configuration(
            model: "gpt-6-luna-2026-09-22",
            baseURL: URL(string: "https://proxy.example/openai/v1")!,
            reasoningEffort: nil,
            verbosity: "medium",
            maxOutputTokens: 500
        )
        let request = try CommitMessageGenerator(configuration: configuration, transport: MockTransport()).makeRequest(prompt, apiKey: "k")
        #expect(request.url?.absoluteString == "https://proxy.example/openai/v1/responses")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning"] == nil)
        #expect(json["model"] as? String == "gpt-6-luna-2026-09-22")
        #expect(json["text"] as? [String: String] == ["verbosity": "medium"])
        #expect(json["max_output_tokens"] as? Int == 500)
    }

    @Test func missingKeyFailsWithoutARequest() async {
        let transport = MockTransport(body: SSE.stream(["x"]))
        let generator = CommitMessageGenerator(transport: transport)
        await #expect(throws: CommitMessageError.missingAPIKey) {
            _ = try await collect(generator.generate(prompt, apiKey: " \n"))
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    // MARK: Streaming

    @Test func streamsAccumulatedTextAndEndsWithTheFinalMessage() async throws {
        let transport = MockTransport(body: SSE.stream(["Add", " commit", " engine\n\n", "Details."]))
        let values = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        #expect(values == ["Add", "Add commit", "Add commit engine\n\n", "Add commit engine\n\nDetails.", "Add commit engine\n\nDetails."])
    }

    @Test func ignoresNonDeltaEventsAndAcceptsDoneSentinel() async throws {
        let body = SSE.event("response.in_progress", [:])
            + SSE.delta("Fix typo")
            + SSE.event("response.output_text.done", ["text": "SHOULD NOT APPEAR"])
            + "data: [DONE]\n\n"
        let values = try await collect(CommitMessageGenerator(transport: MockTransport(body: body)).generate(prompt, apiKey: "k"))
        #expect(values.last == "Fix typo")
    }

    @Test func stripsCodeFenceWhileStreamingAndAtTheEnd() async throws {
        let transport = MockTransport(body: SSE.stream(["``", "`text\nAdd ", "parser\n", "```"]))
        let values = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        #expect(!values.contains { $0.contains("`") })
        #expect(values.last == "Add parser")
    }

    @Test func streamThatStopsWithoutTerminalEventIsANetworkError() async {
        let transport = MockTransport(body: SSE.event("response.created", [:]) + SSE.delta("Half"))
        await #expect(throws: CommitMessageError.network) {
            _ = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        }
    }

    @Test func completedWithoutTextIsEmptyResponse() async {
        let transport = MockTransport(body: SSE.stream(["  ", "\n"]))
        await #expect(throws: CommitMessageError.emptyResponse) {
            _ = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        }
    }

    @Test func cancellingTheConsumerStopsTheRequest() async throws {
        let transport = HangingTransport()
        let stream = CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k")
        let consumer = Task { for try await _ in stream {} }
        try await waitUntil { transport.sent.withLock { $0 } }
        consumer.cancel()
        _ = await consumer.result
        try await waitUntil { transport.terminated.withLock { $0 } }
    }

    // MARK: Errors

    struct HTTPCase: Sendable, CustomTestStringConvertible {
        var status: Int
        var headers: [String: String] = [:]
        var body = ""
        var expected: CommitMessageError
        var testDescription: String { "\(status) → \(expected)" }
    }

    @Test(arguments: [
        HTTPCase(status: 401, body: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#, expected: .invalidAPIKey),
        HTTPCase(status: 401, expected: .invalidAPIKey),
        HTTPCase(status: 429, headers: ["Retry-After": "7"], body: #"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#, expected: .rateLimited(retryAfter: .seconds(7))),
        HTTPCase(status: 429, headers: ["retry-after-ms": "1500", "Retry-After": "9"], expected: .rateLimited(retryAfter: .milliseconds(1500))),
        HTTPCase(status: 429, expected: .rateLimited(retryAfter: nil)),
        HTTPCase(status: 429, body: #"{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}"#, expected: .quotaExceeded),
        HTTPCase(status: 400, body: #"{"error":{"message":"Your input exceeds the context window of this model.","code":null}}"#, expected: .diffTooLarge),
        HTTPCase(status: 400, body: #"{"error":{"message":"x","code":"context_length_exceeded"}}"#, expected: .diffTooLarge),
        HTTPCase(status: 404, body: #"{"error":{"message":"The model does not exist","code":"model_not_found"}}"#, expected: .modelUnavailable("gpt-6-luna")),
        HTTPCase(status: 500, body: "<html>oops</html>", expected: .serverUnavailable),
        HTTPCase(status: 503, expected: .serverUnavailable),
        HTTPCase(status: 400, body: #"{"error":{"message":"Unsupported parameter: 'foo'.","code":"unsupported_parameter"}}"#, expected: .rejected(status: 400, message: "Unsupported parameter: 'foo'.")),
    ])
    func httpErrorsMapToTypedErrors(_ http: HTTPCase) async {
        let transport = MockTransport(status: http.status, headers: http.headers, body: http.body)
        await #expect(throws: http.expected) {
            _ = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        }
    }

    @Test func retryAfterIsParsedFromSecondsMillisecondsAndDates() throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: headers)!
        }
        #expect(CommitMessageGenerator.retryAfter(response(["Retry-After": "12"])) == .seconds(12))
        #expect(CommitMessageGenerator.retryAfter(response(["retry-after-ms": "250"])) == .milliseconds(250))
        #expect(CommitMessageGenerator.retryAfter(response([:])) == nil)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let later = now.addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(CommitMessageGenerator.retryAfter(response(["Retry-After": formatter.string(from: later)]), now: now) == .seconds(30))
    }

    @Test(arguments: [
        (SSE.event("response.failed", ["response": ["status": "failed", "error": ["code": "server_error", "message": "boom"]]]), CommitMessageError.serverUnavailable),
        (SSE.event("response.failed", ["response": ["status": "failed", "error": ["code": "weird", "message": "Nope"]]]), .rejected(status: nil, message: "Nope")),
        (SSE.event("response.incomplete", ["response": ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]]]), .cutOff(reason: "max_output_tokens")),
        (SSE.event("error", ["code": "context_length_exceeded", "message": "too big", "param": NSNull()]), .diffTooLarge),
        (SSE.event("error", ["code": "rate_limit_exceeded", "message": "slow down"]), .rateLimited(retryAfter: nil)),
    ] as [(String, CommitMessageError)])
    func streamErrorEventsMapToTypedErrors(end: String, expected: CommitMessageError) async {
        let transport = MockTransport(body: SSE.stream(["Partial"], end: end))
        await #expect(throws: expected) {
            _ = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        }
    }

    @Test func transportFailuresBecomeNetworkErrors() async {
        let transport = MockTransport(failure: URLError(.notConnectedToInternet))
        await #expect(throws: CommitMessageError.network) {
            _ = try await collect(CommitMessageGenerator(transport: transport).generate(prompt, apiKey: "k"))
        }
    }

    @Test func userMessagesUseTheResearchedWording() {
        #expect(CommitMessageError.invalidAPIKey.userMessage == "OpenAI API key is invalid or missing. Check it in Settings → AI.")
        #expect(CommitMessageError.rateLimited(retryAfter: nil).userMessage == "OpenAI rate limit hit. Try again in a few seconds.")
        #expect(CommitMessageError.rateLimited(retryAfter: .milliseconds(1500)).userMessage == "OpenAI rate limit hit. Try again in 2s.")
        #expect(CommitMessageError.serverUnavailable.userMessage == "OpenAI is having trouble right now. Try again shortly.")
        #expect(CommitMessageError.diffTooLarge.userMessage == "This diff is too large to summarize. Try staging fewer files.")
        #expect(CommitMessageError.network.userMessage == "Couldn't reach OpenAI. Check your connection.")
    }

    // MARK: Cleanup

    @Test(arguments: [
        ("```text\nAdd parser\n\nBody line\n```", "Add parser\n\nBody line"),
        ("```\nFix bug\n```\n", "Fix bug"),
        ("\"Update README\"", "Update README"),
        ("“Update README”", "Update README"),
        ("  feat(ai): add generator  \n", "feat(ai): add generator"),
        ("Don't strip 'inner' quotes", "Don't strip 'inner' quotes"),
        ("Refactor the very long subject line that goes well beyond seventy-two characters on purpose", "Refactor the very long subject line that goes well beyond seventy-two characters on purpose"),
    ])
    func finalCleanup(raw: String, cleaned: String) {
        #expect(CommitMessageCleanup.final(raw) == cleaned)
    }

    @Test func partialCleanupHidesFenceFragments() {
        #expect(CommitMessageCleanup.partial("``") == "")
        #expect(CommitMessageCleanup.partial("```te") == "")
        #expect(CommitMessageCleanup.partial("```text\nAdd") == "Add")
        #expect(CommitMessageCleanup.partial("```text\nAdd x\n``") == "Add x")
        #expect(CommitMessageCleanup.partial("Add `code`") == "Add `code`")
    }
}
