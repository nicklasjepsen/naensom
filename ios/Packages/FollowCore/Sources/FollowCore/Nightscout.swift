import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything the site refused or answered in a shape that is not Nightscout entries. The messages are
/// fit for the screen and never carry the address, the token or a response body.
public enum NightscoutError: Error, Equatable, Sendable {
    case invalidAddress
    case notHTTPS
    case unreachable
    case timedOut
    case tokenRefused
    case status(Int)
    case notNightscout

    public var message: String { message(in: .en) }

    public func message(in language: Language) -> String {
        if language == .da {
            switch self {
            case .invalidAddress: return "Det ligner ikke en webadresse"
            case .notHTTPS: return "Sidens adresse skal begynde med https://"
            case .unreachable: return "Kunne ikke få forbindelse til siden"
            case .timedOut: return "Siden var for længe om at svare"
            case .tokenRefused: return "Tokenet blev afvist. Tjek det under Indstillinger"
            case .status(let code): return "Siden svarede \(code)"
            case .notNightscout: return "Siden svarede med noget, der ikke er Nightscout-data"
            }
        }
        switch self {
        case .invalidAddress: return "That doesn't look like a web address"
        case .notHTTPS: return "The site address must start with https://"
        case .unreachable: return "Couldn't reach the site"
        case .timedOut: return "The site took too long to answer"
        case .tokenRefused: return "The token was refused. Check it under Settings"
        case .status(let code): return "The site answered \(code)"
        case .notNightscout: return "The site answered something that isn't Nightscout data"
        }
    }
}

/// The one HTTP call FollowCore makes. The app uses `URLSessionTransport`; tests use a stub.
public protocol HTTPTransport: Sendable {
    /// Sends the request and answers the body and the HTTP status. Throws only for transport
    /// failures (no connection, timeout), as `NightscoutError`.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Reads the newest sensor readings from a Nightscout site. Read-only: every call it can make is a
/// `GET`: `/api/v1/entries/sgv.json` (the same endpoint the desktop app and Nænsom's poller read),
/// `/api/v1/status.json`, and `/api/v1/treatments.json` for reservoir, site and sensor changes only
/// (`PumpChanges.swift`). The token goes in the `api-secret` header, never in the URL, so it stays
/// out of server logs.
public struct NightscoutClient: Sendable {
    /// Paths this client requests, all `GET`; `treatmentsPath` is in `PumpChanges.swift`.
    public static let entriesPath = "/api/v1/entries/sgv.json"
    public static let statusPath = "/api/v1/status.json"

    let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// "ns.example.org", "https://ns.example.org/" and " https://ns.example.org/sub/ " become an
    /// https URL with no trailing slash. Plain http is refused: iOS would block it anyway, and the
    /// token must not travel in the clear.
    public static func normalizeBaseURL(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // "https://" loses its slashes above and would otherwise read as a host called "https".
        if trimmed.isEmpty || trimmed.hasSuffix(":") { throw NightscoutError.invalidAddress }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw NightscoutError.invalidAddress }
        guard scheme == "https" else { throw NightscoutError.notHTTPS }
        guard components.query == nil, components.fragment == nil, let url = components.url else {
            throw NightscoutError.invalidAddress
        }
        return url
    }

    /// The request for the newest `count` readings; separate so tests can check exactly what is sent.
    public static func entriesRequest(baseURL: URL, token: String, count: Int) -> URLRequest {
        getRequest(baseURL: baseURL, path: entriesPath, token: token, query: [URLQueryItem(name: "count", value: String(max(1, count)))])
    }

    /// The request for every reading from `since` on (the newest `limit` of them): the same
    /// `find[date][$gte]=<ms>&count=<n>` the poller's Nightscout source sends.
    public static func entriesRequest(baseURL: URL, token: String, since: Date, limit: Int) -> URLRequest {
        let milliseconds = Int64((since.timeIntervalSince1970 * 1000).rounded(.down))
        return getRequest(baseURL: baseURL, path: entriesPath, token: token, query: [
            URLQueryItem(name: "find[date][$gte]", value: String(milliseconds)),
            URLQueryItem(name: "count", value: String(max(1, limit))),
        ])
    }

    /// The request for the site's status, which carries its colour thresholds.
    public static func statusRequest(baseURL: URL, token: String) -> URLRequest {
        getRequest(baseURL: baseURL, path: statusPath, token: token, query: nil)
    }

    private static func getRequest(baseURL: URL, path: String, token: String, query: [URLQueryItem]?) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path + path
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "api-secret") }
        return request
    }

    /// The newest readings, newest first.
    public func latest(site: String, token: String, count: Int = 2) async throws -> [Reading] {
        let base = try Self.normalizeBaseURL(site)
        return try await entries(Self.entriesRequest(baseURL: base, token: token, count: count))
    }

    /// Every reading from `since` on, newest first, however many the site holds for that time (up
    /// to `limit`). A curve is read this way, by time: a count of expected readings falls short on
    /// a site that stores each reading twice or uploads every minute, and leaves a hole.
    public func readings(site: String, token: String, since: Date, limit: Int) async throws -> [Reading] {
        let base = try Self.normalizeBaseURL(site)
        return try await entries(Self.entriesRequest(baseURL: base, token: token, since: since, limit: limit))
    }

    private func entries(_ request: URLRequest) async throws -> [Reading] {
        let (body, status) = try await transport.send(request)
        if status == 401 || status == 403 { throw NightscoutError.tokenRefused }
        guard (200..<300).contains(status) else { throw NightscoutError.status(status) }
        return try Self.parseEntries(body)
    }

    /// The site's own colour thresholds (`settings.thresholds` in `status.json`), or nil when it
    /// sends none that make sense; the app then uses Nightscout's defaults.
    public func thresholds(site: String, token: String) async throws -> GlucoseThresholds? {
        let base = try Self.normalizeBaseURL(site)
        let (body, status) = try await transport.send(Self.statusRequest(baseURL: base, token: token))
        if status == 401 || status == 403 { throw NightscoutError.tokenRefused }
        guard (200..<300).contains(status) else { throw NightscoutError.status(status) }
        return GlucoseThresholds.fromNightscoutStatus(body)
    }

    /// Nightscout's entries array, newest first, one per timestamp. Entries without an `sgv` of 1–720
    /// or a numeric `date` (meter readings, calibrations, nonsense) are skipped; anything that is
    /// not an array is refused.
    public static func parseEntries(_ data: Data) throws -> [Reading] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = root as? [Any]
        else { throw NightscoutError.notNightscout }

        // One reading per timestamp (a site can send the same entry twice), so the newest is never
        // compared with itself.
        var byDate: [Double: Reading] = [:]
        for case let entry as [String: Any] in array {
            guard let sgv = number(entry["sgv"]), let date = number(entry["date"]) else { continue }
            // The same bounds as the poller's parser; checked before the Int conversion, which
            // would trap on a value like 1e100.
            guard sgv >= 1, sgv <= 720, date > 0, date < 1e15, byDate[date] == nil else { continue }
            let mgdl = Int(sgv.rounded(.toNearestOrAwayFromZero))
            let direction = entry["direction"] as? String ?? ""
            byDate[date] = Reading(at: Date(timeIntervalSince1970: date / 1000), mgdl: mgdl, direction: direction)
        }
        return byDate.values.sorted { $0.at > $1.at }
    }

    static func number(_ value: Any?) -> Double? {
        // JSONSerialization gives NSNumber on Apple platforms and Int/Double on Linux; a Bool is
        // an NSNumber too, and is not a number here.
        #if canImport(Darwin)
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
        #else
        // An NSNumber holding 0 or 1 also answers `is Bool`, so ask the number what it was made
        // from before asking Swift: only a real boolean is refused, and zero stays a number.
        if let n = value as? NSNumber {
            let type = String(cString: n.objCType)
            return type == "c" || type == "B" ? nil : n.doubleValue
        }
        if value is Bool { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
        #endif
    }
}

/// `URLSession` with redirects refused, so the `api-secret` header is never handed to another host.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public override init() {
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .timedOut {
            throw NightscoutError.timedOut
        } catch {
            throw NightscoutError.unreachable
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
