import Foundation

/// Sends one HTTP request and returns the response head plus its body as a byte stream.
/// The seam that lets tests feed canned SSE without a network.
public protocol CommitMessageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<UInt8, any Error>)
}

/// The real transport. Ephemeral session: no cookies, no disk cache of prompts or replies.
public struct URLSessionTransport: CommitMessageTransport {
    public static let ephemeralSession = URLSession(configuration: .ephemeral)

    public let session: URLSession

    public init(session: URLSession = URLSessionTransport.ephemeralSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (HTTPURLResponse, any AsyncSequence<UInt8, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http, bytes)
    }
}

/// Streams a commit message from the OpenAI Responses API.
///
/// ```swift
/// let prompt = CommitPromptBuilder().build(from: try await repo.commitContext())
/// for try await message in generator.generate(prompt, apiKey: key) {
///     field.text = message
/// }
/// ```
public struct CommitMessageGenerator: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// A setting, not a constant: OpenAI may ship dated snapshots.
        public var model: String
        public var baseURL: URL
        /// nil leaves the field out, for models without reasoning controls.
        public var reasoningEffort: String?
        public var verbosity: String?
        public var maxOutputTokens: Int
        /// Seconds without a byte from OpenAI before the request fails.
        public var idleTimeout: TimeInterval

        public init(
            model: String = "gpt-6-luna",
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            reasoningEffort: String? = "none",
            verbosity: String? = "low",
            maxOutputTokens: Int = 300,
            idleTimeout: TimeInterval = 60
        ) {
            self.model = model
            self.baseURL = baseURL
            self.reasoningEffort = reasoningEffort
            self.verbosity = verbosity
            self.maxOutputTokens = maxOutputTokens
            self.idleTimeout = idleTimeout
        }
    }

    public var configuration: Configuration
    public let transport: any CommitMessageTransport

    public init(configuration: Configuration = Configuration(), transport: any CommitMessageTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Each element is the whole message so far — assign it to the field, don't append.
    /// The last element is the final, cleaned message. Fails with `CommitMessageError`,
    /// or `CancellationError` when cancelled. Cancelling the consuming task (or dropping
    /// the stream) cancels the network request.
    public func generate(_ prompt: CommitPrompt, apiKey: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(prompt, apiKey: apiKey, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    struct RequestBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        struct Reasoning: Encodable { var effort: String }
        struct Text: Encodable { var verbosity: String }

        var model: String
        var input: [Message]
        var reasoning: Reasoning?
        var text: Text?
        var maxOutputTokens: Int
        var stream: Bool
        /// Don't keep diffs on OpenAI's side for the dashboard log.
        var store: Bool

        enum CodingKeys: String, CodingKey {
            case model, input, reasoning, text, stream, store
            case maxOutputTokens = "max_output_tokens"
        }
    }

    func makeRequest(_ prompt: CommitPrompt, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CommitMessageError.missingAPIKey }

        let body = RequestBody(
            model: configuration.model,
            input: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
            reasoning: configuration.reasoningEffort.map { .init(effort: $0) },
            text: configuration.verbosity.map { .init(verbosity: $0) },
            maxOutputTokens: configuration.maxOutputTokens,
            stream: true,
            store: false
        )
        var request = URLRequest(url: configuration.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.idleTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Streaming

    private func stream(_ prompt: CommitPrompt, apiKey: String, into continuation: AsyncThrowingStream<String, any Error>.Continuation) async throws {
        let request = try makeRequest(prompt, apiKey: apiKey)
        let (response, body) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            let data = try await Self.collect(body, limit: 64 * 1024)
            let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error
            throw CommitMessageError.from(status: response.statusCode, error: apiError, retryAfter: Self.retryAfter(response), model: configuration.model)
        }

        var parser = SSEParser()
        var state = ResponseStreamState(model: configuration.model)
        var shown = ""
        func show() {
            let partial = CommitMessageCleanup.partial(state.text)
            if partial != shown {
                shown = partial
                continuation.yield(partial)
            }
        }

        var finished = false
        for try await byte in body {
            guard let event = parser.push(byte) else { continue }
            switch try state.handle(event) {
            case .updated: show()
            case .finished: finished = true
            case .ignored: break
            }
            if finished { break }
        }
        if !finished, let event = parser.finish() {
            finished = try state.handle(event) == .finished
        }
        try Task.checkCancellation()
        // A stream that just stops, with no terminal event, is a dropped connection.
        guard finished else { throw CommitMessageError.network }

        let message = CommitMessageCleanup.final(state.text)
        guard !message.isEmpty else { throw CommitMessageError.emptyResponse }
        continuation.yield(message)
    }

    static func collect(_ body: any AsyncSequence<UInt8, any Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in body {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// OpenAI's SDKs prefer `retry-after-ms`, then `Retry-After` (seconds or an HTTP date).
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init), ms >= 0 {
            return .milliseconds(ms)
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(value), seconds >= 0 { return .seconds(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now)))
    }

    static func map(_ error: any Error) -> any Error {
        switch error {
        case is CommitMessageError, is CancellationError: error
        case let url as URLError where url.code == .cancelled: CancellationError()
        default: CommitMessageError.network
        }
    }

    struct ErrorEnvelope: Decodable {
        var error: CommitMessageError.APIError?
    }
}

/// Folds Responses API stream events into text. Only `response.output_text.delta` adds
/// text; terminal events end the stream or throw.
struct ResponseStreamState {
    enum Step: Equatable { case ignored, updated, finished }

    let model: String
    private(set) var text = ""

    init(model: String) {
        self.model = model
    }

    private struct Payload: Decodable {
        struct Response: Decodable {
            struct Incomplete: Decodable { var reason: String? }
            var error: CommitMessageError.APIError?
            var incompleteDetails: Incomplete?

            enum CodingKeys: String, CodingKey {
                case error
                case incompleteDetails = "incomplete_details"
            }
        }
        var type: String?
        var delta: String?
        var response: Response?
        // The `error` event carries these at the top level.
        var code: String?
        var message: String?
        var error: CommitMessageError.APIError?
    }

    mutating func handle(_ event: ServerSentEvent) throws -> Step {
        if event.data == "[DONE]" { return .finished }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(event.data.utf8)) else { return .ignored }

        switch payload.type ?? event.event {
        case "response.output_text.delta":
            guard let delta = payload.delta, !delta.isEmpty else { return .ignored }
            text += delta
            return .updated
        case "response.completed":
            return .finished
        case "response.incomplete":
            throw CommitMessageError.cutOff(reason: payload.response?.incompleteDetails?.reason)
        case "response.failed":
            throw failure(payload.response?.error)
        case "error":
            throw failure(payload.error ?? .init(message: payload.message, type: nil, code: payload.code))
        default:
            return .ignored
        }
    }

    private func failure(_ error: CommitMessageError.APIError?) -> CommitMessageError {
        CommitMessageError.from(apiError: error, model: model) ?? .rejected(status: nil, message: error?.message ?? "")
    }
}
