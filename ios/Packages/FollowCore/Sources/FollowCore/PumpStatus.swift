import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One figure the pump reported, with the time the pump recorded it.
public struct PumpFigure<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var at: Date

    public init(_ value: Value, at: Date) {
        self.value = value
        self.at = at
    }
}

/// How a pump figure is shown for its age: as it is, greyed because the pump has said nothing
/// newer for a while, or not at all because it is too old to mean anything now.
public enum PumpFigureAge: Equatable, Sendable {
    case fresh
    case old
    case withheld
}

/// What the pump last said about itself, as the Nightscout site has it (`devicestatus`, written by
/// the pump's uploader; tconnectsync for a Tandem pump): its battery, the insulin it counts as
/// still active, and the insulin left in its reservoir.
///
/// These are the pump's own figures, shown as reported and with their age. Nothing here is
/// calculated, carried forward between records, or typed in the app, and nothing says what to do.
public struct PumpStatus: Equatable, Sendable {
    /// Percent, 0 to 100.
    public var battery: PumpFigure<Int>?
    /// Units the pump counts as still active.
    public var iob: PumpFigure<Double>?
    /// Units left in the reservoir.
    public var reservoir: PumpFigure<Double>?

    public init(battery: PumpFigure<Int>? = nil, iob: PumpFigure<Double>? = nil, reservoir: PumpFigure<Double>? = nil) {
        self.battery = battery
        self.iob = iob
        self.reservoir = reservoir
    }

    /// True when the site has sent none of the three; the app then shows nothing about the pump.
    public var isEmpty: Bool { battery == nil && iob == nil && reservoir == nil }

    // MARK: - Ages

    /// Active insulin changes by the minute: the pump records it every ten minutes, so half an hour
    /// without a newer one is old, and after six hours the figure says nothing about now.
    public static let iobFresh: TimeInterval = 30 * 60
    public static let iobShown: TimeInterval = 6 * 3600
    /// The pump writes the reservoir when its screen is used, so not overnight: old after twelve
    /// hours, gone after three days.
    public static let reservoirFresh: TimeInterval = 12 * 3600
    public static let reservoirShown: TimeInterval = 3 * 86_400
    /// The battery moves slowly: old after three hours, gone after three days.
    public static let batteryFresh: TimeInterval = 3 * 3600
    public static let batteryShown: TimeInterval = 3 * 86_400

    public static func age(of at: Date, now: Date, fresh: TimeInterval, shown: TimeInterval) -> PumpFigureAge {
        let age = now.timeIntervalSince(at)
        if age <= fresh { return .fresh }
        return age <= shown ? .old : .withheld
    }

    public func iobAge(now: Date) -> PumpFigureAge? {
        iob.map { Self.age(of: $0.at, now: now, fresh: Self.iobFresh, shown: Self.iobShown) }
    }

    public func reservoirAge(now: Date) -> PumpFigureAge? {
        reservoir.map { Self.age(of: $0.at, now: now, fresh: Self.reservoirFresh, shown: Self.reservoirShown) }
    }

    public func batteryAge(now: Date) -> PumpFigureAge? {
        battery.map { Self.age(of: $0.at, now: now, fresh: Self.batteryFresh, shown: Self.batteryShown) }
    }

    // MARK: - Battery

    /// The battery symbol's filling: red under 20 percent, yellow under 50, green from there.
    public enum BatteryLevel: Equatable, Sendable {
        case low
        case medium
        case good
    }

    public static func batteryLevel(percent: Int) -> BatteryLevel {
        if percent < 20 { return .low }
        return percent < 50 ? .medium : .good
    }

    // MARK: - Words

    /// The number alone, as the pump shows it: active insulin with two decimals ("1,24"), the
    /// reservoir in whole units ("115"), in the locale's decimal separator.
    public static func formatIOB(_ units: Double, locale: Locale) -> String {
        let text = String(format: "%.2f", units)
        let separator = locale.decimalSeparator ?? "."
        return separator == "." ? text : text.replacingOccurrences(of: ".", with: separator)
    }

    public static func formatReservoir(_ units: Double) -> String {
        String(format: "%.0f", units)
    }

    /// The unit's letter: "E" (enheder) in Danish, "U" in English.
    public static func unitLabel(_ language: Language) -> String {
        language == .da ? "E" : "U"
    }

    /// Made-up figures for the demo: a battery two thirds full and the active insulin six minutes
    /// ago, the reservoir forty minutes ago.
    public static func demo(now: Date) -> PumpStatus {
        PumpStatus(
            battery: PumpFigure(64, at: now.addingTimeInterval(-6 * 60)),
            iob: PumpFigure(1.35, at: now.addingTimeInterval(-6 * 60)),
            reservoir: PumpFigure(85, at: now.addingTimeInterval(-40 * 60))
        )
    }
}

extension NightscoutClient {
    /// The device status endpoint, read with `find[pump.<field>][$exists]` and `count=1` only, `GET`.
    public static let deviceStatusPath = "/api/v1/devicestatus.json"
    /// The three parts of a `pump` object the app reads; each is asked for by itself, because an
    /// uploader may write them in separate records (tconnectsync writes the reservoir when the
    /// pump's screen was used and the rest every ten minutes).
    public static let pumpStatusFields = ["pump.iob", "pump.reservoir", "pump.battery"]
    /// How far back a record is looked for; nothing older is ever shown (`PumpStatus.reservoirShown`).
    public static let pumpStatusWindow: TimeInterval = 3 * 86_400

    /// The request for the newest device status that has `field`, since `since`.
    public static func pumpStatusRequest(baseURL: URL, token: String, field: String, since: Date) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path + deviceStatusPath
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        components.queryItems = [
            URLQueryItem(name: "find[\(field)][$exists]", value: "true"),
            URLQueryItem(name: "find[created_at][$gte]", value: formatter.string(from: since)),
            URLQueryItem(name: "count", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "api-secret") }
        return request
    }

    /// The pump's newest battery, active insulin and reservoir of the last three days. A token
    /// without read access to device status, or any other refusal, throws like the readings do.
    public func pumpStatus(site: String, token: String, now: Date = Date()) async throws -> PumpStatus {
        let base = try Self.normalizeBaseURL(site)
        let since = now.addingTimeInterval(-Self.pumpStatusWindow)
        var status = PumpStatus()
        for field in Self.pumpStatusFields {
            let request = Self.pumpStatusRequest(baseURL: base, token: token, field: field, since: since)
            let (body, code) = try await transport.send(request)
            if code == 401 || code == 403 { throw NightscoutError.tokenRefused }
            guard (200..<300).contains(code) else { throw NightscoutError.status(code) }
            status = Self.newest(status, try Self.parsePumpStatus(body, now: now))
        }
        return status
    }

    /// Each figure from whichever of the two has the newer one.
    static func newest(_ a: PumpStatus, _ b: PumpStatus) -> PumpStatus {
        func pick<V>(_ x: PumpFigure<V>?, _ y: PumpFigure<V>?) -> PumpFigure<V>? {
            guard let x else { return y }
            guard let y else { return x }
            return y.at > x.at ? y : x
        }
        return PumpStatus(battery: pick(a.battery, b.battery), iob: pick(a.iob, b.iob), reservoir: pick(a.reservoir, b.reservoir))
    }

    /// The newest of each figure in a device status answer. A record without a `pump` object or a
    /// readable time, or one dated more than ten minutes ahead of `now` (a pump clock or an uploader
    /// sent a future time), is skipped; so is a figure that is not a number or is out of range.
    /// Anything not an array is refused. Zero is a figure like any other.
    public static func parsePumpStatus(_ data: Data, now: Date = Date()) throws -> PumpStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = root as? [Any]
        else { throw NightscoutError.notNightscout }
        var status = PumpStatus()
        let latest = now.addingTimeInterval(changeFutureSlack)
        for case let entry as [String: Any] in array {
            guard let pump = entry["pump"] as? [String: Any] else { continue }
            let recordAt = [entry["created_at"], pump["clock"]].compactMap { ($0 as? String).flatMap(parseDate) }.first
            guard let recordAt, recordAt <= latest else { continue }
            var one = PumpStatus()
            if let battery = pump["battery"] as? [String: Any], let percent = number(battery["percent"]),
               percent.isFinite, (0...100).contains(percent) {
                one.battery = PumpFigure(Int(percent.rounded()), at: recordAt)
            }
            if let iob = pump["iob"] as? [String: Any], let units = number(iob["iob"]) ?? number(iob["bolusiob"]),
               units.isFinite, units >= 0 {
                let at = (iob["timestamp"] as? String).flatMap(parseDate) ?? recordAt
                if at <= latest { one.iob = PumpFigure(units, at: at) }
            }
            if let units = number(pump["reservoir"]), units.isFinite, units >= 0 {
                one.reservoir = PumpFigure(units, at: recordAt)
            }
            status = newest(status, one)
        }
        return status
    }
}

extension ReadingFeed {
    /// The pump's newest figures for the source; the demo's are made up.
    public func pumpStatus(_ source: FollowSource, now: Date = Date()) async throws -> PumpStatus {
        switch source {
        case .demo:
            return PumpStatus.demo(now: now)
        case .nightscout(let site, let token):
            return try await client.pumpStatus(site: site.absoluteString, token: token, now: now)
        }
    }
}
