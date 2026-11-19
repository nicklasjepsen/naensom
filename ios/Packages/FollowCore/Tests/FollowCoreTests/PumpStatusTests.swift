import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FollowCore

/// Answers each request by the `pump.<field>` it asks for, and records every request.
final class StatusTransport: HTTPTransport, @unchecked Sendable {
    let bodies: [String: String]
    let status: Int
    private(set) var requests: [URLRequest] = []

    init(bodies: [String: String], status: Int = 200) {
        self.bodies = bodies
        self.status = status
    }

    static func field(_ request: URLRequest) -> String {
        let names = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        let name = names.first { $0.hasSuffix("[$exists]") } ?? ""
        return String(name.dropFirst("find[".count).dropLast("][$exists]".count))
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (Data((bodies[Self.field(request)] ?? "[]").utf8), status)
    }
}

final class PumpStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_112_400) // 2026-11-19T18:20:00Z
    let iso = ISO8601DateFormatter()

    /// What tconnectsync writes: the battery and active insulin every ten minutes, and the
    /// reservoir with the battery when the pump's screen was used.
    let tenMinute = #"""
    [{"device":"Pump (tconnectsync)","created_at":"2026-11-19T18:14:21+00:00",
      "pump":{"clock":"2026-11-19T18:14:21+00:00","battery":{"voltage":3.83,"percent":55,"status":"55%"},
              "iob":{"timestamp":"2026-11-19T18:14:21+00:00","iob":1.2431}},"pump_event_id":"442700"}]
    """#
    let screen = #"""
    [{"device":"Pump (tconnectsync)","created_at":"2026-11-19T17:26:21+00:00",
      "pump":{"clock":"2026-11-19T17:26:21+00:00","reservoir":115,"battery":{"percent":57}},"pump_event_id":"442650"}]
    """#

    func testReadsEachFigureFromTheRecordThatHasItWithItsOwnTime() async throws {
        let transport = StatusTransport(bodies: ["pump.iob": tenMinute, "pump.reservoir": screen, "pump.battery": tenMinute])
        let status = try await NightscoutClient(transport: transport).pumpStatus(site: "ns.example.org", token: "t", now: now)
        XCTAssertEqual(status.iob, PumpFigure(1.2431, at: iso.date(from: "2026-11-19T18:14:21Z")!))
        XCTAssertEqual(status.reservoir, PumpFigure(115, at: iso.date(from: "2026-11-19T17:26:21Z")!))
        // The battery is in both records; the newer one wins.
        XCTAssertEqual(status.battery, PumpFigure(55, at: iso.date(from: "2026-11-19T18:14:21Z")!))
    }

    func testAsksOnlyDeviceStatusWithGetOneRecordPerFieldAndTheTokenInTheHeader() async throws {
        let transport = StatusTransport(bodies: [:])
        let status = try await NightscoutClient(transport: transport).pumpStatus(site: "https://ns.example.org", token: "secret", now: now)
        XCTAssertTrue(status.isEmpty)
        XCTAssertEqual(transport.requests.map(StatusTransport.field), ["pump.iob", "pump.reservoir", "pump.battery"])
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/devicestatus.json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "secret")
            XCTAssertFalse(request.url!.absoluteString.contains("secret"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "count" }?.value, "1")
            XCTAssertEqual(items.first { $0.name.hasSuffix("[$exists]") }?.value, "true")
            let since = items.first { $0.name == "find[created_at][$gte]" }?.value ?? ""
            XCTAssertTrue(since.hasPrefix("2026-11-16T18:20:00"), since)
        }
    }

    func testARefusedTokenThrowsLikeTheReadings() async {
        let transport = StatusTransport(bodies: [:], status: 401)
        do {
            _ = try await NightscoutClient(transport: transport).pumpStatus(site: "ns.example.org", token: "t", now: now)
            XCTFail("expected tokenRefused")
        } catch {
            XCTAssertEqual(error as? NightscoutError, .tokenRefused)
        }
    }

    func testZeroIsAFigure() throws {
        let body = #"[{"created_at":"2026-11-19T18:10:00Z","pump":{"reservoir":0,"battery":{"percent":0},"iob":{"iob":0.0}}}]"#
        let status = try NightscoutClient.parsePumpStatus(Data(body.utf8), now: now)
        XCTAssertEqual(status.iob?.value, 0)
        XCTAssertEqual(status.reservoir?.value, 0)
        XCTAssertEqual(status.battery?.value, 0)
    }

    func testSkipsFutureRecordsRecordsWithoutATimeAndFiguresThatAreNotNumbers() throws {
        let body = #"""
        [{"created_at":"2026-11-19T19:00:00Z","pump":{"reservoir":200,"battery":{"percent":90},"iob":{"iob":9}}},
         {"created_at":"not a time","pump":{"reservoir":150}},
         {"created_at":"2026-11-19T18:00:00Z","loop":{"iob":{"iob":3}}},
         {"created_at":"2026-11-19T18:05:00Z","pump":{"reservoir":"many","battery":{"percent":140},"iob":{"iob":true}}},
         {"created_at":"2026-11-19T18:06:00Z","pump":{"reservoir":-4,"iob":{"iob":-0.2}}},
         {"created_at":"2026-11-19T18:01:00Z","pump":{"reservoir":88.4,"battery":{"percent":41.6},"iob":{"bolusiob":0.5}}}]
        """#
        let status = try NightscoutClient.parsePumpStatus(Data(body.utf8), now: now)
        let at = iso.date(from: "2026-11-19T18:01:00Z")!
        XCTAssertEqual(status, PumpStatus(battery: PumpFigure(42, at: at), iob: PumpFigure(0.5, at: at), reservoir: PumpFigure(88.4, at: at)))
    }

    func testARecordTenMinutesAheadIsStillRead() throws {
        // The pump's clock may run a few minutes ahead.
        let body = #"[{"created_at":"2026-11-19T18:29:00Z","pump":{"reservoir":70}}]"#
        XCTAssertEqual(try NightscoutClient.parsePumpStatus(Data(body.utf8), now: now).reservoir?.value, 70)
    }

    func testTheActiveInsulinKeepsItsOwnTimestampWhenItHasOne() throws {
        let body = #"[{"created_at":"2026-11-19T18:10:00Z","pump":{"iob":{"timestamp":"2026-11-19T18:04:00Z","iob":2.5}}}]"#
        XCTAssertEqual(try NightscoutClient.parsePumpStatus(Data(body.utf8), now: now).iob?.at, iso.date(from: "2026-11-19T18:04:00Z"))
    }

    func testAnythingButAnArrayIsRefused() {
        XCTAssertThrowsError(try NightscoutClient.parsePumpStatus(Data(#"{"status":401}"#.utf8), now: now))
    }

    func testAges() {
        let status = PumpStatus(
            battery: PumpFigure(80, at: now.addingTimeInterval(-4 * 3600)),
            iob: PumpFigure(1, at: now.addingTimeInterval(-30 * 60)),
            reservoir: PumpFigure(100, at: now.addingTimeInterval(-4 * 86_400))
        )
        XCTAssertEqual(status.iobAge(now: now), .fresh)
        XCTAssertEqual(status.iobAge(now: now.addingTimeInterval(1)), .old)
        XCTAssertEqual(status.iobAge(now: now.addingTimeInterval(6 * 3600)), .withheld)
        XCTAssertEqual(status.batteryAge(now: now), .old)
        XCTAssertEqual(status.reservoirAge(now: now), .withheld)
        XCTAssertNil(PumpStatus().iobAge(now: now))
    }

    func testBatteryLevels() {
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 0), .low)
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 19), .low)
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 20), .medium)
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 49), .medium)
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 50), .good)
        XCTAssertEqual(PumpStatus.batteryLevel(percent: 100), .good)
    }

    func testWords() {
        XCTAssertEqual(PumpStatus.formatIOB(1.2431, locale: Locale(identifier: "da_DK")), "1,24")
        XCTAssertEqual(PumpStatus.formatIOB(0, locale: Locale(identifier: "en_US")), "0.00")
        XCTAssertEqual(PumpStatus.formatReservoir(115), "115")
        XCTAssertEqual(PumpStatus.unitLabel(.da), "E")
        XCTAssertEqual(PumpStatus.unitLabel(.en), "U")
        XCTAssertEqual(Glucose.ageText(at: now.addingTimeInterval(-12 * 60), now: now, language: .da), "12 min siden")
    }

    func testTheDemoIsMadeUpAndFresh() async throws {
        let status = try await ReadingFeed(client: NightscoutClient(transport: StatusTransport(bodies: [:]))).pumpStatus(.demo, now: now)
        XCTAssertEqual(status, PumpStatus.demo(now: now))
        XCTAssertEqual(status.iobAge(now: now), .fresh)
        XCTAssertEqual(status.reservoirAge(now: now), .fresh)
        XCTAssertEqual(status.batteryAge(now: now), .fresh)
    }
}
