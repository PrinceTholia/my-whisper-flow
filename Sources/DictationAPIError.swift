import Foundation

/// User-visible failure from Groq / STT / LLM calls.
enum DictationAPIError: Equatable {
    case noAPIKey(provider: String)
    case network(String)
    case http(status: Int, message: String, retryAfter: TimeInterval?)
    case rateLimited(retryAfter: TimeInterval, detail: String)
    case emptyResponse
    case invalidKey

    /// Short line for the floating pill.
    var pillMessage: String {
        switch self {
        case .noAPIKey:
            return "Add Groq API key in Settings"
        case .invalidKey:
            return "Invalid API key — check Settings"
        case .network(let m):
            return "Network: \(m)"
        case .rateLimited(let sec, _):
            let s = Int(ceil(sec))
            return "Rate limit — wait ~\(s)s"
        case .http(let status, let message, let retry):
            if status == 429 {
                let s = Int(ceil(retry ?? 60))
                return "Rate limit — wait ~\(s)s"
            }
            if !message.isEmpty { return String(message.prefix(42)) }
            return "API error \(status)"
        case .emptyResponse:
            return "No speech detected"
        }
    }

    /// Longer tooltip / status explanation.
    var detailMessage: String {
        switch self {
        case .noAPIKey(let p):
            return "No API key for \(p). Open Settings and paste your Groq key."
        case .invalidKey:
            return "Groq rejected the API key. Create a new one at console.groq.com."
        case .network(let m):
            return "Network error: \(m)"
        case .rateLimited(let sec, let detail):
            let s = Int(ceil(sec))
            return "Groq free-tier limit hit. Wait about \(s)s then try again. \(detail)"
        case .http(let status, let message, let retry):
            if status == 429 {
                let s = Int(ceil(retry ?? 60))
                return "Rate limited (HTTP 429). Wait ~\(s)s. \(message)"
            }
            return "HTTP \(status): \(message)"
        case .emptyResponse:
            return "No speech detected — hold Fn a bit longer and speak closer to the mic."
        }
    }

    /// How long to keep the error overlay visible.
    var displaySeconds: TimeInterval {
        switch self {
        case .rateLimited(let sec, _):
            return min(max(sec, 3), 90)
        case .http(_, _, let retry):
            if let retry { return min(max(retry, 3), 90) }
            return 4
        default:
            return 4
        }
    }

    static func fromHTTP(status: Int, data: Data?, headers: [AnyHashable: Any]?) -> DictationAPIError {
        let retry = parseRetryAfter(headers: headers)
        let (message, type) = parseErrorBody(data)

        if status == 401 || status == 403 {
            return .invalidKey
        }
        if status == 429 || type.contains("rate_limit") {
            // Groq free tier: often resets within a minute; use header or default 60s
            let wait = retry ?? suggestedWait(from: message) ?? 60
            return .rateLimited(retryAfter: wait, detail: message)
        }
        return .http(status: status, message: message.isEmpty ? "Request failed" : message, retryAfter: retry)
    }

    private static func parseRetryAfter(headers: [AnyHashable: Any]?) -> TimeInterval? {
        guard let headers else { return nil }
        // URLSession gives string values for HTTPURLResponse.allHeaderFields
        let raw = headers["Retry-After"] ?? headers["retry-after"]
        if let s = raw as? String, let v = Double(s) { return v }
        if let n = raw as? NSNumber { return n.doubleValue }
        // Groq sometimes sends x-ratelimit-reset-*
        for key in ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens",
                    "x-ratelimit-reset"] {
            if let s = (headers[key] ?? headers[key.lowercased()]) as? String {
                if let v = Double(s) { return v }
                // May be a unix timestamp
                if let ts = Double(s), ts > 1_000_000_000 {
                    return max(0, ts - Date().timeIntervalSince1970)
                }
            }
        }
        return nil
    }

    private static func parseErrorBody(_ data: Data?) -> (message: String, type: String) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", "")
        }
        if let err = json["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? ""
            let type = (err["type"] as? String) ?? (err["code"] as? String) ?? ""
            return (msg, type.lowercased())
        }
        if let msg = json["message"] as? String { return (msg, "") }
        return ("", "")
    }

    private static func suggestedWait(from message: String) -> TimeInterval? {
        // e.g. "Please try again in 22.5s" or "try again in 1m"
        let lower = message.lowercased()
        if let r = lower.range(of: #"(\d+(?:\.\d+)?)\s*s"#, options: .regularExpression) {
            return Double(lower[r].replacingOccurrences(of: "s", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
        if let r = lower.range(of: #"(\d+(?:\.\d+)?)\s*m"#, options: .regularExpression) {
            if let m = Double(lower[r].replacingOccurrences(of: "m", with: "")
                .trimmingCharacters(in: .whitespaces)) {
                return m * 60
            }
        }
        return nil
    }
}
