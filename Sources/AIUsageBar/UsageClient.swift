import Foundation

// MARK: - Models (everything optional: the endpoint is internal and may change)

struct UsageResponse: Codable, Equatable {
    var fiveHour: Window?
    var sevenDay: Window?
    var limits: [Limit]?
    var extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
        case extraUsage = "extra_usage"
    }

    struct Window: Codable, Equatable {
        var utilization: Double?
        var resetsAt: Date?
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
    }

    struct Limit: Codable, Equatable, Identifiable {
        var kind: String?
        var group: String?
        var percent: Double?
        var severity: String?
        var resetsAt: Date?
        var scope: Scope?
        var isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        struct Scope: Codable, Equatable {
            var model: Model?
            var surface: String?
            struct Model: Codable, Equatable {
                var id: String?
                var displayName: String?
                enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
            }
        }

        var id: String { "\(kind ?? "")|\(scope?.model?.displayName ?? "")|\(scope?.surface ?? "")" }

        var title: String {
            switch kind {
            case "session": return "All models 5h"
            case "weekly_all": return "All models weekly"
            case "weekly_scoped":
                if let m = scope?.model?.displayName { return "\(m) weekly" }
                if let s = scope?.surface { return "\(s) weekly" }
                return "Scoped weekly"
            default: return kind?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Limit"
            }
        }
    }

    /// The account's extra-usage credits: a monthly spend cap the account owner sets, billed
    /// at API rates once the subscription's windows are used up. Account-wide, not per model.
    /// Amounts come in the currency's minor unit (`decimal_places` of them per major unit).
    struct ExtraUsage: Codable, Equatable {
        var isEnabled: Bool?
        var utilization: Double?
        var usedCredits: Double?
        var monthlyLimit: Double?
        var currency: String?
        var decimalPlaces: Int?
        enum CodingKeys: String, CodingKey {
            case utilization, currency
            case isEnabled = "is_enabled"
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
            case decimalPlaces = "decimal_places"
        }

        /// The account has credits to show; a disabled account sends every amount as null.
        var isActive: Bool { isEnabled == true }

        /// Percent of the month's cap spent: the endpoint's figure, else used over limit.
        var percent: Double? {
            if let utilization { return utilization }
            guard let used = usedCredits, let limit = monthlyLimit, limit > 0 else { return nil }
            return used / limit * 100
        }

        /// "$12.40 of $50.00 this month"; nil until both amounts are known.
        var detailText: String? {
            guard let used = usedCredits, let limit = monthlyLimit else { return nil }
            let scale = pow(10.0, Double(decimalPlaces ?? 2))
            return "\(Self.money(used / scale, currency)) of \(Self.money(limit / scale, currency)) this month"
        }

        /// "$12.40", "€12.40", "XYZ 12.40": the ISO code's symbol as en_US writes it, so the
        /// text matches the dollar figures on the cost rows.
        static func money(_ amount: Double, _ currency: String?) -> String {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US")
            f.numberStyle = .currency
            f.currencyCode = currency ?? "USD"
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            return f.string(from: amount as NSNumber) ?? String(format: "%.2f", amount)
        }
    }

    /// Rows to display. Prefers `limits`; falls back to the two legacy windows.
    var displayLimits: [Limit] {
        if let limits, !limits.isEmpty { return limits }
        var rows: [Limit] = []
        if let w = fiveHour { rows.append(Limit(kind: "session", group: "session", percent: w.utilization, resetsAt: w.resetsAt)) }
        if let w = sevenDay { rows.append(Limit(kind: "weekly_all", group: "weekly", percent: w.utilization, resetsAt: w.resetsAt)) }
        return rows
    }

    var sessionPercent: Double? { displayLimits.first { $0.kind == "session" }?.percent }
    var weeklyPercent: Double? { displayLimits.first { $0.kind == "weekly_all" }?.percent }
    var weeklyResetsAt: Date? { displayLimits.first { $0.kind == "weekly_all" }?.resetsAt }
    var highestPercent: Double? { displayLimits.compactMap(\.percent).max() }
}

// MARK: - HTTP abstraction (injectable for tests)

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

// MARK: - Usage endpoint

enum UsageError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token rejected (401)."
        case .rateLimited(let s): return "Rate limited (429). Retrying in \(Int(s / 60)) min."
        case .http(let code): return "Usage endpoint returned HTTP \(code)."
        case .decoding(let msg): return "Could not read usage response: \(msg)"
        }
    }
}

struct UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let defaultBackoff: TimeInterval = 15 * 60

    var http: HTTPClient = URLSessionHTTPClient()

    static let decoder = makeDecoder()

    /// ISO-8601 with or without fractional seconds. Callers that decode off the main actor
    /// (the token scanner) make their own instance instead of sharing `decoder`.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    func fetch(accessToken: String) async throws -> UsageResponse {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let resp = try await http.send(req)
        switch resp.status {
        case 200:
            do { return try Self.decoder.decode(UsageResponse.self, from: resp.body) }
            catch { throw UsageError.decoding(String(describing: error)) }
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retry = resp.header("Retry-After").flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
                ?? Self.defaultBackoff
            throw UsageError.rateLimited(retryAfter: max(60, retry))
        default:
            throw UsageError.http(resp.status)
        }
    }
}
