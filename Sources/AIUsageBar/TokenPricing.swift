import Foundation

// MARK: - Pricing

/// USD per million tokens. Cache write is 1.25x input for the 5 m TTL and 2x for 1 h;
/// cache read is a multiplier of input. Costs are estimates: list prices, no discounts.
/// The Gemini rows are the Gemini API's paid tier, which is what Antigravity's generations
/// are estimated at (Antigravity reports no cache writes, and its context window stays under
/// the 200k-token threshold where Pro prices step up).
enum TokenPricing {
    struct Rate: Equatable {
        let input: Double
        let output: Double
        let cacheReadMultiplier: Double
    }

    static let cacheWrite5m = 1.25
    static let cacheWrite1h = 2.0

    /// Model id prefixes and their list prices. Order does not matter: `rate(for:)` takes the longest match.
    static let rates: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1",  Rate(input: 10, output: 50, cacheReadMultiplier: 0.025)),
        ("claude-fable-5",    Rate(input: 10, output: 50, cacheReadMultiplier: 0.1)),
        ("claude-opus-5",     Rate(input: 5,  output: 25, cacheReadMultiplier: 0.1)),
        ("claude-opus-4-8",   Rate(input: 5,  output: 25, cacheReadMultiplier: 0.1)),
        ("claude-opus-4-7",   Rate(input: 5,  output: 25, cacheReadMultiplier: 0.1)),
        ("claude-opus-4-6",   Rate(input: 5,  output: 25, cacheReadMultiplier: 0.1)),
        ("claude-sonnet-5",   Rate(input: 2,  output: 10, cacheReadMultiplier: 0.1)),
        ("claude-sonnet-4-6", Rate(input: 3,  output: 15, cacheReadMultiplier: 0.1)),
        ("claude-haiku-4-5",  Rate(input: 1,  output: 5,  cacheReadMultiplier: 0.1)),
        // Gemini API paid tier (ai.google.dev/gemini-api/docs/pricing); cache read is 10% of input
        // throughout. The 3.6 to 3.8 Flash rows are the introductory prices in force through 2026-12-31.
        ("gemini-3.8-flash",      Rate(input: 0.75, output: 3.75, cacheReadMultiplier: 0.1)),
        ("gemini-3.7-flash",      Rate(input: 0.75, output: 3.75, cacheReadMultiplier: 0.1)),
        ("gemini-3.6-flash",      Rate(input: 0.75, output: 3.75, cacheReadMultiplier: 0.1)),
        ("gemini-3.5-flash",      Rate(input: 1.5,  output: 9,    cacheReadMultiplier: 0.1)),
        ("gemini-3.5-flash-lite", Rate(input: 0.3,  output: 2.5,  cacheReadMultiplier: 0.1)),
        ("gemini-3.1-pro",        Rate(input: 2,    output: 12,   cacheReadMultiplier: 0.1)),
        ("gemini-3.1-flash-lite", Rate(input: 0.25, output: 1.5,  cacheReadMultiplier: 0.1)),
        ("gemini-3-flash",        Rate(input: 0.5,  output: 3,    cacheReadMultiplier: 0.1)),
        ("gemini-2.5-pro",        Rate(input: 1.25, output: 10,   cacheReadMultiplier: 0.1)),
        ("gemini-2.5-flash",      Rate(input: 0.3,  output: 2.5,  cacheReadMultiplier: 0.1)),
        ("gemini-2.5-flash-lite", Rate(input: 0.1,  output: 0.4,  cacheReadMultiplier: 0.1)),
        // Antigravity's aliases for its default Pro model ("gemini-pro-default", "gemini-pro-agent").
        ("gemini-pro",            Rate(input: 2,    output: 12,   cacheReadMultiplier: 0.1)),
    ]

    /// Longest prefix that ends at the id end or at a "-", so `claude-fable-5-1` never
    /// claims a hypothetical `claude-fable-5-10` and `claude-fable-5` does not claim `claude-fable-5-1`.
    static func rate(for model: String) -> Rate? {
        var best: (length: Int, rate: Rate)?
        for entry in rates where model.hasPrefix(entry.prefix) {
            let end = model.index(model.startIndex, offsetBy: entry.prefix.count)
            guard end == model.endIndex || model[end] == "-" else { continue }
            if best == nil || entry.prefix.count > best!.length {
                best = (entry.prefix.count, entry.rate)
            }
        }
        return best?.rate
    }

    /// USD for one record, nil when the model is not in the table.
    static func cost(_ record: TokenRecord) -> Double? {
        guard let rate = rate(for: record.model) else { return nil }
        let usd = Double(record.input) * rate.input
            + Double(record.output) * rate.output
            + Double(record.cacheWrite5m) * rate.input * cacheWrite5m
            + Double(record.cacheWrite1h) * rate.input * cacheWrite1h
            + Double(record.cacheRead) * rate.input * rate.cacheReadMultiplier
        return usd / 1_000_000
    }
}

// MARK: - Totals

/// Token counts and estimated cost over a window. Tokens from unknown models are still
/// counted in the buckets but flagged in `unpricedTokens`, so the cost reads as a floor.
struct TokenTotals: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var cost = 0.0
    var unpricedTokens = 0

    var tokens: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ r: TokenRecord) {
        input += r.input
        output += r.output
        cacheWrite += r.cacheWrite5m + r.cacheWrite1h
        cacheRead += r.cacheRead
        if let usd = TokenPricing.cost(r) {
            cost += usd
        } else {
            unpricedTokens += r.total
        }
    }

    /// Sums every record with `timestamp >= start`.
    static func sum(_ records: [TokenRecord], since start: Date) -> TokenTotals {
        var t = TokenTotals()
        for r in records where r.timestamp >= start { t.add(r) }
        return t
    }
}
