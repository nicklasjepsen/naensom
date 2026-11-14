import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FollowCore

/// Answers each request by its `find[eventType]`, and records every request.
final class ChangesTransport: HTTPTransport, @unchecked Sendable {
    let bodies: [String: String]
    let status: Int
    private(set) var requests: [URLRequest] = []

    init(bodies: [String: String], status: Int = 200) {
        self.bodies = bodies
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let type = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "find[eventType]" }?.value ?? ""
        return (Data((bodies[type] ?? "[]").utf8), status)
    }
}

final class PumpChangesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_657_600) // 2026-11-14T12:00:00Z

    /// What tconnectsync writes for one change: three Site Change fills a few minutes apart.
    let tconnect = #"""
    [
      {"eventType":"Site Change","created_at":"2026-11-12T09:02:00.000Z","notes":"Tubing Filled (12u primed)","pump_event_id":"903"},
      {"eventType":"Site Change","created_at":"2026-11-12T09:05:00.000Z","notes":"Cannula Filled (0.3u primed)","pump_event_id":"904"},
      {"eventType":"Site Change","created_at":"2026-11-12T09:00:00.000Z","notes":"Cartridge Filled (200u filled)","pump_event_id":"902"},
      {"eventType":"Site Change","created_at":"2026-11-10T08:00:00.000Z","notes":"Cartridge Filled (180u filled)","pump_event_id":"801"},
      {"eventType":"Site Change","created_at":"not a time","notes":"Cannula Filled"}
    ]
    """#

    func testReadsTconnectsyncFillsAsReservoirAndSite() async throws {
        let transport = ChangesTransport(bodies: ["Site Change": tconnect])
        let changes = try await NightscoutClient(transport: transport).pumpChanges(site: "ns.example.org", token: "t", now: now)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(changes.cartridgeAt, iso.date(from: "2026-11-12T09:00:00Z"))
        XCTAssertEqual(changes.cannulaAt, iso.date(from: "2026-11-12T09:05:00Z"))
    }

    func testAsksOnlyForTheTwoChangeTypesWithGetAndTheTokenInTheHeader() async throws {
        let transport = ChangesTransport(bodies: [:])
        _ = try await NightscoutClient(transport: transport).pumpChanges(site: "https://ns.example.org", token: "secret", now: now)
        XCTAssertEqual(transport.requests.count, 2)
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/treatments.json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "secret")
            XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        }
        let types = transport.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "find[eventType]" }?.value
        }
        XCTAssertEqual(types, ["Site Change", "Insulin Change"])
    }

    func testReadsCareportalEntries() throws {
        let site = try NightscoutClient.parseChanges(Data(#"[{"eventType":"Site Change","created_at":"2026-11-13T20:00:00Z"}]"#.utf8), eventType: "Site Change")
        XCTAssertEqual(site.map(\.0), [.cannula])
        let insulin = try NightscoutClient.parseChanges(Data(#"[{"eventType":"Insulin Change","created_at":"2026-11-13T20:10:00Z"}]"#.utf8), eventType: "Insulin Change")
        XCTAssertEqual(insulin.map(\.0), [.cartridge])
    }

    func testARefusedTokenThrows() async {
        let transport = ChangesTransport(bodies: [:], status: 401)
        do {
            _ = try await NightscoutClient(transport: transport).pumpChanges(site: "ns.example.org", token: "t", now: now)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NightscoutError, .tokenRefused)
        }
    }

    func testCountdownUsesOneUnitAPersonWouldSay() {
        let at = { (hours: Double) in self.now.addingTimeInterval(hours * 3600) }
        XCTAssertEqual(PumpCountdown.to(nil, now: now), .unknown)
        XCTAssertEqual(PumpCountdown.to(at(22), now: now), .due(1, .day))
        XCTAssertEqual(PumpCountdown.to(at(30), now: now), .due(1, .day))
        XCTAssertEqual(PumpCountdown.to(at(40), now: now), .due(2, .day))
        XCTAssertEqual(PumpCountdown.to(at(5.4), now: now), .due(5, .hour))
        XCTAssertEqual(PumpCountdown.to(at(0.5), now: now), .due(30, .minute))
        XCTAssertEqual(PumpCountdown.to(at(0.01), now: now), .now)
        XCTAssertEqual(PumpCountdown.to(at(-3), now: now), .overdue(3, .hour))
    }

    func testCountdownWordsInBothLanguages() {
        XCTAssertEqual(PumpCountdown.due(1, .day).text(in: .da), "Skiftes om 1 dag")
        XCTAssertEqual(PumpCountdown.due(2, .day).text(in: .en), "Change in 2 days")
        XCTAssertEqual(PumpCountdown.overdue(3, .hour).text(in: .da), "Skulle skiftes for 3 timer siden")
        XCTAssertEqual(PumpCountdown.overdue(1, .hour).text(in: .en), "Was due 1 hour ago")
        XCTAssertEqual(PumpCountdown.unknown.text(in: .da), "Intet skift fra pumpen endnu")
    }

    func testDueAtIsTheLastFillPlusTheDays() {
        XCTAssertEqual(PumpCountdown.dueAt(lastAt: now, days: 3), now.addingTimeInterval(3 * 86_400))
        XCTAssertNil(PumpCountdown.dueAt(lastAt: nil, days: 3))
    }

    func testDemoHasOneDueAndOnePastDue() {
        let demo = PumpChanges.demo(now: now)
        XCTAssertEqual(PumpCountdown.to(PumpCountdown.dueAt(lastAt: demo.cartridgeAt, days: 3), now: now), .due(1, .day))
        XCTAssertEqual(PumpCountdown.to(PumpCountdown.dueAt(lastAt: demo.cannulaAt, days: 3), now: now), .overdue(3, .hour))
    }

    func testSettingsKeepTheDaysAndFallBackToThree() {
        var settings = FollowSettings.defaults
        XCTAssertEqual(settings.days(for: .cartridge), 3)
        settings.setDays(2, for: .cannula)
        settings.setDays(99, for: .cartridge)
        XCTAssertEqual(settings.cannulaDays, 2)
        XCTAssertEqual(settings.cartridgeDays, 10)
        XCTAssertEqual(FollowSettings.load(settings.encoded()), settings)
        let old = FollowSettings.load(Data(#"{"alertsOn":true}"#.utf8))
        XCTAssertEqual(old.cartridgeDays, 3)
        XCTAssertEqual(old.cannulaDays, 3)
    }
}
