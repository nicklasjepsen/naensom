import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The two pump parts with a change interval: the reservoir (cartridge) and the site (infusion
/// set, cannula). Nothing here is insulin: the time of a fill and the days a part lasts.
public enum PumpPart: String, CaseIterable, Codable, Sendable {
    case cartridge
    case cannula
}

/// The newest reservoir and site fill the pump recorded, as the Nightscout site has them. Read
/// from the pump's own upload (tconnectsync for a Tandem pump); never typed in the app.
public struct PumpChanges: Equatable, Sendable {
    public var cartridgeAt: Date?
    public var cannulaAt: Date?

    public init(cartridgeAt: Date? = nil, cannulaAt: Date? = nil) {
        self.cartridgeAt = cartridgeAt
        self.cannulaAt = cannulaAt
    }

    public subscript(part: PumpPart) -> Date? {
        switch part {
        case .cartridge: return cartridgeAt
        case .cannula: return cannulaAt
        }
    }

    /// True when the site has sent neither; the app then shows nothing about changes.
    public var isEmpty: Bool { cartridgeAt == nil && cannulaAt == nil }

    /// Made-up changes for the demo: the reservoir filled 50 hours ago and the site 75 hours ago,
    /// so with 3 days each one is due in a day and the other is just past due.
    public static func demo(now: Date) -> PumpChanges {
        PumpChanges(cartridgeAt: now.addingTimeInterval(-50 * 3600), cannulaAt: now.addingTimeInterval(-75 * 3600))
    }
}

/// How far away a change is, in the one unit a person would say ("in 1 day", "in 5 hours").
public enum PumpCountdown: Equatable, Sendable {
    public enum Unit: Equatable, Sendable { case day, hour, minute }
    case unknown
    case now
    case due(Int, Unit)
    case overdue(Int, Unit)

    public static let defaultDays = 3
    public static let dayChoices = 1...10

    /// When a part is due: its last fill plus its interval in days.
    public static func dueAt(lastAt: Date?, days: Int) -> Date? {
        lastAt.map { $0.addingTimeInterval(TimeInterval(days) * 86_400) }
    }

    /// Whole days from 22 hours (rounded, so 30 hours is "1 day" and 40 hours "2 days"), hours from
    /// an hour, minutes below that; within a minute either way it is "now". The same rules as the
    /// web app's countdown (`web/src/components/pump/change-text.ts`).
    public static func to(_ dueAt: Date?, now: Date) -> PumpCountdown {
        guard let dueAt else { return .unknown }
        let seconds = dueAt.timeIntervalSince(now)
        let distance = abs(seconds)
        if distance < 60 { return .now }
        let value: Int
        let unit: Unit
        if distance >= 22 * 3600 {
            value = max(1, Int((distance / 86_400).rounded(.toNearestOrAwayFromZero)))
            unit = .day
        } else if distance >= 3600 {
            value = Int((distance / 3600).rounded(.toNearestOrAwayFromZero))
            unit = .hour
        } else {
            value = max(1, Int((distance / 60).rounded(.toNearestOrAwayFromZero)))
            unit = .minute
        }
        return seconds > 0 ? .due(value, unit) : .overdue(value, unit)
    }

    public var isPastDue: Bool {
        switch self {
        case .now, .overdue: return true
        default: return false
        }
    }

    /// "Skiftes om 1 dag" / "Change in 1 day", "Skulle skiftes for 3 timer siden" / "Was due 3 hours ago".
    public func text(in language: Language) -> String {
        switch (self, language) {
        case (.unknown, .da): return "Intet skift fra pumpen endnu"
        case (.unknown, .en): return "No change from the pump yet"
        case (.now, .da): return "Skiftes nu"
        case (.now, .en): return "Change now"
        case (.due(let n, let unit), .da): return "Skiftes om \(Self.amount(n, unit, .da))"
        case (.due(let n, let unit), .en): return "Change in \(Self.amount(n, unit, .en))"
        case (.overdue(let n, let unit), .da): return "Skulle skiftes for \(Self.amount(n, unit, .da)) siden"
        case (.overdue(let n, let unit), .en): return "Was due \(Self.amount(n, unit, .en)) ago"
        }
    }

    static func amount(_ n: Int, _ unit: Unit, _ language: Language) -> String {
        switch (unit, language) {
        case (.day, .da): return n == 1 ? "1 dag" : "\(n) dage"
        case (.hour, .da): return n == 1 ? "1 time" : "\(n) timer"
        case (.minute, .da): return n == 1 ? "1 minut" : "\(n) minutter"
        case (.day, .en): return n == 1 ? "1 day" : "\(n) days"
        case (.hour, .en): return n == 1 ? "1 hour" : "\(n) hours"
        case (.minute, .en): return n == 1 ? "1 minute" : "\(n) minutes"
        }
    }
}

extension NightscoutClient {
    /// The treatments endpoint, read with `find[eventType]` set to a change type only, `GET`.
    public static let treatmentsPath = "/api/v1/treatments.json"
    /// tconnectsync writes every fill as `Site Change` and names it in `notes`/`reason`; Nightscout's
    /// careportal writes `Site Change` for the site and `Insulin Change` for the reservoir.
    public static let changeEventTypes = ["Site Change", "Insulin Change"]
    /// Fills read back; a part is never worn longer than this.
    public static let changeWindow: TimeInterval = 14 * 86_400

    /// The request for the newest change records of one type since `since`.
    public static func changesRequest(baseURL: URL, token: String, eventType: String, since: Date) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path + treatmentsPath
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        components.queryItems = [
            URLQueryItem(name: "find[eventType]", value: eventType),
            URLQueryItem(name: "find[created_at][$gte]", value: formatter.string(from: since)),
            URLQueryItem(name: "count", value: "30"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "api-secret") }
        return request
    }

    /// The newest reservoir and site fill of the last 14 days. A token without read access to
    /// treatments, or any other refusal, throws like the readings do.
    public func pumpChanges(site: String, token: String, now: Date = Date()) async throws -> PumpChanges {
        let base = try Self.normalizeBaseURL(site)
        var changes = PumpChanges()
        let since = now.addingTimeInterval(-Self.changeWindow)
        for eventType in Self.changeEventTypes {
            let request = Self.changesRequest(baseURL: base, token: token, eventType: eventType, since: since)
            let (body, status) = try await transport.send(request)
            if status == 401 || status == 403 { throw NightscoutError.tokenRefused }
            guard (200..<300).contains(status) else { throw NightscoutError.status(status) }
            for (part, at) in try Self.parseChanges(body, eventType: eventType) {
                switch part {
                case .cartridge: changes.cartridgeAt = max(changes.cartridgeAt ?? at, at)
                case .cannula: changes.cannulaAt = max(changes.cannulaAt ?? at, at)
                }
            }
        }
        return changes
    }

    /// The part each record of `eventType` is about, with its time. A tubing fill, another type,
    /// or a record without a readable `created_at` is skipped; anything not an array is refused.
    public static func parseChanges(_ data: Data, eventType: String) throws -> [(PumpPart, Date)] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = root as? [Any]
        else { throw NightscoutError.notNightscout }
        var out: [(PumpPart, Date)] = []
        for case let entry as [String: Any] in array {
            guard let type = entry["eventType"] as? String, type == eventType,
                  let created = entry["created_at"] as? String, let at = parseDate(created),
                  let part = part(eventType: type, notes: entry["notes"], reason: entry["reason"])
            else { continue }
            out.append((part, at))
        }
        return out
    }

    /// "Cartridge Filled …" is the reservoir and "Tubing Filled …" nothing; any other `Site Change`
    /// is the site. `Insulin Change` is the reservoir.
    static func part(eventType: String, notes: Any?, reason: Any?) -> PumpPart? {
        if eventType == "Insulin Change" { return .cartridge }
        guard eventType == "Site Change" else { return nil }
        let words = [notes, reason].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let text = words.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("cartridge filled") { return .cartridge }
        if text.hasPrefix("tubing filled") { return nil }
        return .cannula
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

extension ReadingFeed {
    /// The newest reservoir and site fill for the source; the demo's are made up.
    public func pumpChanges(_ source: FollowSource, now: Date = Date()) async throws -> PumpChanges {
        switch source {
        case .demo:
            return PumpChanges.demo(now: now)
        case .nightscout(let site, let token):
            return try await client.pumpChanges(site: site.absoluteString, token: token, now: now)
        }
    }
}
