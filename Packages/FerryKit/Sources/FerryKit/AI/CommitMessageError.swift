import Foundation

/// Why a commit message couldn't be generated. `userMessage` is the one sentence the
/// inline error shows. Never carries the API key.
public enum CommitMessageError: Error, Sendable, Equatable {
    case missingAPIKey
    /// 401.
    case invalidAPIKey
    /// 429. `retryAfter` comes from `retry-after-ms` / `Retry-After` when OpenAI sends one.
    case rateLimited(retryAfter: Duration?)
    /// 429 with `insufficient_quota`: waiting won't help, billing will.
    case quotaExceeded
    /// 404 or `model_not_found` — the configured model id isn't available to this key.
    case modelUnavailable(String)
    /// The prompt exceeded the model's context.
    case diffTooLarge
    /// 5xx, or OpenAI reported a server error mid-stream.
    case serverUnavailable
    /// Offline, DNS, TLS, timeout, or the stream ended without a terminal event.
    case network
    /// `response.incomplete`, e.g. the output-token cap cut the message off.
    case cutOff(reason: String?)
    /// Any other refusal; `message` is OpenAI's own text.
    case rejected(status: Int?, message: String)
    /// Completed, but with no text.
    case emptyResponse

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Add your OpenAI API key in Settings → AI to generate commit messages."
        case .invalidAPIKey:
            "OpenAI API key is invalid or missing. Check it in Settings → AI."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter.map(Self.wholeSeconds), seconds > 0 {
                "OpenAI rate limit hit. Try again in \(seconds)s."
            } else {
                "OpenAI rate limit hit. Try again in a few seconds."
            }
        case .quotaExceeded:
            "Your OpenAI account is out of credit. Check your billing settings with OpenAI."
        case .modelUnavailable(let model):
            "The model “\(model)” isn’t available with this API key. Check the model in Settings → AI."
        case .diffTooLarge:
            "This diff is too large to summarize. Try staging fewer files."
        case .serverUnavailable:
            "OpenAI is having trouble right now. Try again shortly."
        case .network:
            "Couldn't reach OpenAI. Check your connection."
        case .cutOff:
            "OpenAI stopped before the message was finished. Try again."
        case .rejected(_, let message):
            message.isEmpty ? "OpenAI couldn't generate a message." : "OpenAI couldn't generate a message: \(message)"
        case .emptyResponse:
            "OpenAI returned an empty message. Try again."
        }
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) + (attoseconds > 0 ? 1 : 0)
    }
}

extension CommitMessageError {
    /// OpenAI's `{"error": {...}}` body, also the payload of `error` stream events.
    struct APIError: Decodable, Sendable {
        var message: String?
        var type: String?
        var code: String?
    }

    /// Maps an HTTP status (and error body, if any) to a case.
    static func from(status: Int, error: APIError?, retryAfter: Duration?, model: String) -> CommitMessageError {
        switch from(apiError: error, model: model) {
        case .rateLimited: return .rateLimited(retryAfter: retryAfter)
        case let mapped?: return mapped
        case nil: break
        }
        switch status {
        case 401: return .invalidAPIKey
        case 404: return .modelUnavailable(model)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .serverUnavailable
        default: return .rejected(status: status, message: error?.message ?? "")
        }
    }

    /// Recognises the error codes that mean the same thing whatever the status — also
    /// used for `response.failed` and `error` events, which have no status.
    static func from(apiError error: APIError?, model: String) -> CommitMessageError? {
        guard let error else { return nil }
        let code = (error.code ?? "").lowercased()
        let message = (error.message ?? "").lowercased()
        switch code {
        case "invalid_api_key": return .invalidAPIKey
        case "insufficient_quota": return .quotaExceeded
        case "model_not_found": return .modelUnavailable(model)
        case "rate_limit_exceeded": return .rateLimited(retryAfter: nil)
        case "server_error": return .serverUnavailable
        default: break
        }
        // Models differ in the exact code for an oversized request, so match
        // on meaning: any length/context complaint means the diff was too big.
        if ["context_length_exceeded", "string_above_max_length", "string_too_long"].contains(code)
            || ["context length", "context window", "maximum context", "too long", "too large", "too many tokens"].contains(where: message.contains) {
            return .diffTooLarge
        }
        return nil
    }
}
