import FerryKit

extension CommitMessageError {
    /// Errors the user fixes in Settings → AI (key or model), so the banner links there.
    var isFixedInSettings: Bool {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .quotaExceeded, .modelUnavailable: true
        default: false
        }
    }
}
