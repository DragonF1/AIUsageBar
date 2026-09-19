import Foundation

/// Google Cloud Service Health, the public dashboard for the services behind Antigravity.
/// `incidents.json` lists the recent incidents across every Google Cloud product; only the two
/// Antigravity runs on are kept: Gemini Code Assist (the `cloudcode-pa` backend the app calls)
/// and the Gemini API (the models). Folded into the same `StatusSummary` the Claude card shows.
struct GoogleStatusClient: StatusFeed {
    static let feedURL = URL(string: "https://status.cloud.google.com/incidents.json")!
    static let pageURL = URL(string: "https://status.cloud.google.com")!

    /// Dashboard product ids and the names the card shows, in card order. The API is listed on
    /// the dashboard as "Vertex Gemini API".
    static let products: [(id: String, name: String)] = [
        ("deUeOEPYanfJ9w8cpyBJ", "Gemini Code Assist"),
        ("Z0FZJAMvEB4j3NbCJs6B", "Gemini API"),
    ]

    var http: HTTPClient = URLSessionHTTPClient()
    var pageURL: URL { Self.pageURL }

    func fetch() async throws -> StatusSummary {
        var req = URLRequest(url: Self.feedURL)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let resp = try await http.send(req)
        guard resp.status == 200 else { throw UsageError.http(resp.status) }
        let incidents: [GoogleIncident]
        do { incidents = try UsageClient.decoder.decode([GoogleIncident].self, from: resp.body) }
        catch { throw UsageError.decoding(String(describing: error)) }
        return Self.summary(incidents)
    }

    /// Open incidents (no `end`) touching a watched product, worst first; every watched product
    /// gets a component row coloured by its worst open incident.
    static func summary(_ incidents: [GoogleIncident]) -> StatusSummary {
        let open = incidents
            .filter { $0.end == nil && !$0.watchedProducts.isEmpty }
            .sorted { a, b in
                if a.impact.rank != b.impact.rank { return a.impact.rank > b.impact.rank }
                return (a.begin ?? .distantPast) > (b.begin ?? .distantPast)
            }
        let components = products.enumerated().map { index, product in
            let worst = open.filter { $0.watchedProducts.contains { $0.id == product.id } }
                .map(\.impact).max { $0.rank < $1.rank } ?? .none
            return StatusSummary.Component(id: product.id, name: product.name, status: worst.componentStatus,
                                           position: index, group: false)
        }
        let worst = open.first?.impact ?? .none
        return StatusSummary(status: .init(indicator: worst.indicator, description: worst.description),
                             components: components,
                             incidents: open.map { $0.incident(pageURL: pageURL) },
                             scheduledMaintenances: [])
    }
}

/// One entry of `incidents.json`, the fields the card uses.
struct GoogleIncident: Codable, Equatable {
    struct Product: Codable, Equatable {
        var id: String
        var title: String?
    }

    struct Update: Codable, Equatable {
        var when: Date?
        /// AVAILABLE | SERVICE_INFORMATION | SERVICE_DISRUPTION | SERVICE_OUTAGE
        var status: String?
        var text: String?
    }

    var id: String
    var begin: Date?
    var end: Date?
    var modified: Date?
    var externalDesc: String?
    /// SERVICE_INFORMATION | SERVICE_DISRUPTION | SERVICE_OUTAGE
    var statusImpact: String?
    var affectedProducts: [Product]?
    var mostRecentUpdate: Update?
    /// Newest first.
    var updates: [Update]?
    /// Relative to the dashboard, "incidents/<id>".
    var uri: String?

    enum CodingKeys: String, CodingKey {
        case id, begin, end, modified, updates, uri
        case externalDesc = "external_desc"
        case statusImpact = "status_impact"
        case affectedProducts = "affected_products"
        case mostRecentUpdate = "most_recent_update"
    }

    /// The dashboard's impact levels, ordered so the worst one wins.
    enum Impact: Int {
        case none = 0, information, disruption, outage

        init(_ raw: String?) {
            switch raw {
            case "SERVICE_OUTAGE": self = .outage
            case "SERVICE_DISRUPTION": self = .disruption
            case "SERVICE_INFORMATION": self = .information
            default: self = .none
            }
        }

        var rank: Int { rawValue }

        /// Statuspage vocabulary, so the card colours it like the Claude one.
        var indicator: String {
            switch self {
            case .outage: return "critical"
            case .disruption: return "major"
            case .information: return "minor"
            case .none: return "none"
            }
        }

        var componentStatus: String {
            switch self {
            case .outage: return "major_outage"
            case .disruption: return "partial_outage"
            case .information: return "degraded_performance"
            case .none: return "operational"
            }
        }

        var description: String {
            switch self {
            case .outage: return "Service Outage"
            case .disruption: return "Service Disruption"
            case .information: return "Service Information"
            case .none: return "All Systems Operational"
            }
        }
    }

    var impact: Impact { Impact(statusImpact) }

    var watchedProducts: [Product] {
        (affectedProducts ?? []).filter { product in GoogleStatusClient.products.contains { $0.id == product.id } }
    }

    /// The card's incident: the summary sentence as the title, the latest update's status as
    /// the badge ("SERVICE DISRUPTION", "AVAILABLE") and its text, Markdown headings dropped.
    func incident(pageURL: URL) -> StatusSummary.Incident {
        let latest = mostRecentUpdate ?? updates?.first
        let updates = (updates ?? []).map {
            StatusSummary.Incident.Update(status: Self.badge($0.status), body: Self.plainText($0.text), updatedAt: $0.when)
        }
        return StatusSummary.Incident(id: id,
                                      name: externalDesc,
                                      impact: impact.indicator,
                                      status: Self.badge(latest?.status),
                                      shortlink: uri.map { pageURL.appendingPathComponent($0).absoluteString },
                                      updatedAt: latest?.when ?? modified,
                                      components: watchedProducts.map { product in
                                          StatusSummary.Component(id: product.id,
                                                                  name: GoogleStatusClient.products.first { $0.id == product.id }?.name ?? product.title,
                                                                  status: impact.componentStatus)
                                      },
                                      incidentUpdates: updates.isEmpty ? latest.map {
                                          [StatusSummary.Incident.Update(status: Self.badge($0.status), body: Self.plainText($0.text), updatedAt: $0.when)]
                                      } : updates)
    }

    /// "SERVICE_DISRUPTION" reads as "service disruption" (the card uppercases it).
    static func badge(_ status: String?) -> String? {
        status?.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    /// Update texts are Markdown: drop heading markers and collapse blank lines.
    static func plainText(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = Substring(line)
            while s.first == "#" { s = s.dropFirst() }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
