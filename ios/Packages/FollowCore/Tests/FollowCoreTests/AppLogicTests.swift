import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FollowCore

private let noon = Date(timeIntervalSince1970: 1_793_016_000) // a five-minute mark

private func reading(_ minutesAgo: Double, _ mgdl: Int, from now: Date = noon) -> Reading {
    Reading(at: now.addingTimeInterval(-minutesAgo * 60), mgdl: mgdl, direction: "Flat")
}

final class DemoCurveTests: XCTestCase {
    func testIsAPureFunctionOfTime() {
        XCTAssertEqual(DemoCurve.latest(now: noon, count: 10), DemoCurve.latest(now: noon, count: 10))
        XCTAssertEqual(DemoCurve.mgdl(at: 1_793_016_000), DemoCurve.mgdl(at: 1_793_016_000))
    }

    func testFollowsTheDocumentedFormula() {
        for t in stride(from: 1_793_016_000.0, to: 1_793_016_000 + 86_400, by: 300) {
            let expected = Int((140 + 55 * sin(2 * Double.pi * t / 10_800) + 18 * sin(2 * Double.pi * t / 2_700 + 1)).rounded(.toNearestOrAwayFromZero))
            XCTAssertEqual(DemoCurve.mgdl(at: t), expected)
        }
    }

    func testReadingsSitOnFiveMinuteMarksNewestFirst() {
        let now = noon.addingTimeInterval(170) // 2 min 50 s past the mark
        let readings = DemoCurve.latest(now: now, count: 4)
        XCTAssertEqual(readings.count, 4)
        XCTAssertEqual(readings[0].at, noon, "the newest is the mark at or before now, never in the future")
        for (newer, older) in zip(readings, readings.dropFirst()) {
            XCTAssertEqual(newer.at.timeIntervalSince(older.at), 300)
        }
        XCTAssertEqual(DemoCurve.latest(now: now, count: 0).count, 1)
    }

    func testStaysPlausibleAndPassesThroughEveryBand() {
        let day = DemoCurve.latest(now: noon, count: 288)
        let values = day.map(\.mgdl)
        XCTAssertGreaterThanOrEqual(values.min()!, 60)
        XCTAssertLessThanOrEqual(values.max()!, 230)
        let bands = Set(values.map { Glucose.band($0, thresholds: .nightscoutDefaults) })
        XCTAssertTrue(bands.isSuperset(of: [.low, .inRange, .high]))
    }

    func testTheArrowFollowsTheChange() {
        for reading in DemoCurve.latest(now: noon, count: 48) {
            let before = DemoCurve.mgdl(at: reading.at.timeIntervalSince1970 - 300)
            let rate = Double(reading.mgdl - before) / 5
            XCTAssertEqual(reading.direction, DemoCurve.direction(perMinute: rate))
            XCTAssertFalse(Glucose.arrow(reading.direction).isEmpty)
        }
        XCTAssertEqual(DemoCurve.direction(perMinute: 0), "Flat")
        XCTAssertEqual(DemoCurve.direction(perMinute: 1.5), "FortyFiveUp")
        XCTAssertEqual(DemoCurve.direction(perMinute: -2), "SingleDown")
        XCTAssertEqual(DemoCurve.direction(perMinute: 3.2), "DoubleUp")
    }

    func testTheFeedServesTheDemoWithoutTheNetwork() async throws {
        let transport = StubTransport(failure: .unreachable)
        let feed = ReadingFeed(client: NightscoutClient(transport: transport))
        let readings = try await feed.latest(.demo, count: 3, now: noon)
        XCTAssertEqual(readings, DemoCurve.latest(now: noon, count: 3))
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

/// A Nightscout site that answers `find[date][$gte]` and `count` like the real one: the newest
/// `count` entries from that time on, newest first. `clock` is the site's present: entries after it
/// have not been uploaded yet.
private final class FakeSite: HTTPTransport, @unchecked Sendable {
    let entries: [(at: Date, mgdl: Int)]
    var clock = Date.distantFuture
    private(set) var requests: [URLRequest] = []

    init(entries: [(at: Date, mgdl: Int)]) {
        self.entries = entries.sorted { $0.at > $1.at }
    }

    /// One reading every five minutes back to `hours` ago, each stored twice, four seconds apart:
    /// a phone and a watch on the same sensor.
    static func doubled(hours: Int, now: Date) -> FakeSite {
        var entries: [(at: Date, mgdl: Int)] = []
        for step in 0..<(hours * 12) {
            let at = now.addingTimeInterval(-Double(step) * 300)
            entries.append((at, 100 + step % 50))
            entries.append((at.addingTimeInterval(-4), 100 + step % 50))
        }
        return FakeSite(entries: entries)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let since = items.first { $0.name == "find[date][$gte]" }.flatMap { Double($0.value ?? "") } ?? 0
        let count = items.first { $0.name == "count" }.flatMap { Int($0.value ?? "") } ?? 10
        let rows = entries.filter { $0.at <= clock && $0.at.timeIntervalSince1970 * 1000 >= since }.prefix(count).map {
            #"{"sgv":\#($0.mgdl),"date":\#(Int64($0.at.timeIntervalSince1970 * 1000)),"direction":"Flat"}"#
        }
        return (Data("[\(rows.joined(separator: ","))]".utf8), 200)
    }
}

final class ReadingFeedHistoryTests: XCTestCase {
    private let source = FollowSource.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token")

    /// The longest time between two readings that follow each other, in seconds.
    private func longestGap(_ readings: [Reading]) -> TimeInterval {
        zip(readings, readings.dropFirst()).map { $0.at.timeIntervalSince($1.at) }.max() ?? 0
    }

    func testANightAwayLeavesNoHoleOnASiteThatStoresEveryReadingTwice() async throws {
        // Opened last evening, then again eight hours later: the curve has every reading between.
        let evening = noon.addingTimeInterval(-8 * 3600)
        let site = FakeSite.doubled(hours: 30, now: noon)
        let feed = ReadingFeed(client: NightscoutClient(transport: site))
        site.clock = evening
        var readings = ReadingHistory.merge([], try await feed.history(source, newest: nil, now: evening), now: evening)
        XCTAssertEqual(readings.first?.at, evening)
        site.clock = noon
        readings = ReadingHistory.merge(readings, try await feed.history(source, newest: readings.first, now: noon), now: noon)

        XCTAssertEqual(readings.first?.at, noon)
        XCTAssertEqual(longestGap(readings), 296, "no reading is further than five minutes from the next")
        XCTAssertEqual(readings.last?.at, noon.addingTimeInterval(-24 * 3600), "the whole day is there")
        XCTAssertEqual(site.requests.count, 2)
    }

    func testTheFirstReadCoversTheWholeDayOnADoubledSite() async throws {
        let feed = ReadingFeed(client: NightscoutClient(transport: FakeSite.doubled(hours: 30, now: noon)))
        let readings = try await feed.history(source, newest: nil, now: noon)
        XCTAssertEqual(readings.count, 2 * 288 + 1)
        XCTAssertEqual(readings.last?.at, noon.addingTimeInterval(-24 * 3600))
    }

    func testASiteSilentForLongerThanADayStillGivesItsNewestReading() async throws {
        let last = noon.addingTimeInterval(-30 * 3600)
        let site = FakeSite(entries: [(last, 140), (last.addingTimeInterval(-300), 130)])
        let feed = ReadingFeed(client: NightscoutClient(transport: site))
        let readings = try await feed.history(source, newest: nil, now: noon)
        XCTAssertEqual(readings.map(\.mgdl), [140])
        XCTAssertEqual(site.requests.count, 2)
        // With a reading in hand already, an empty answer is just that: nothing new, no second read.
        let again = try await feed.history(source, newest: readings.first, now: noon)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(site.requests.count, 3)
    }

    func testTheDemoHistoryIsTheSameCurveWithoutTheNetwork() async throws {
        let transport = StubTransport(failure: .unreachable)
        let feed = ReadingFeed(client: NightscoutClient(transport: transport))
        let day = try await feed.history(.demo, newest: nil, now: noon)
        XCTAssertEqual(day, DemoCurve.latest(now: noon, count: 289))
        let since = try await feed.history(.demo, newest: reading(10, 0), now: noon)
        XCTAssertEqual(since, DemoCurve.latest(now: noon, count: 3))
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

final class ReadingHistoryTests: XCTestCase {
    func testReadsTheFullDayFirstThenFromTheNewestReadingOn() {
        let dayAgo = noon.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(ReadingHistory.fetchStart(newest: nil, now: noon), dayAgo)
        XCTAssertEqual(ReadingHistory.fetchStart(newest: reading(2, 100), now: noon), reading(2, 100).at)
        XCTAssertEqual(ReadingHistory.fetchStart(newest: reading(60 * 13, 100), now: noon), reading(60 * 13, 100).at)
        // Nothing within the day: the whole day again.
        XCTAssertEqual(ReadingHistory.fetchStart(newest: reading(60 * 25, 100), now: noon), dayAgo)
    }

    func testMergesNewestFirstOnePerTimeAndForgetsAfterTwentyFourHours() {
        let old = [reading(10, 100), reading(5, 110), reading(60 * 24 + 1, 90)]
        let fresh = [reading(0, 130), reading(5, 112)]
        let merged = ReadingHistory.merge(old, fresh, now: noon)
        XCTAssertEqual(merged.map(\.mgdl), [130, 112, 100])
    }

    func testKeepsTheNewestReadingHoweverOld() {
        // A site silent for more than 24 hours still shows its last value (grey, with its age).
        let fresh = [reading(60 * 25, 140), reading(60 * 26, 130)]
        XCTAssertEqual(ReadingHistory.merge([], fresh, now: noon).map(\.mgdl), [140])
        XCTAssertTrue(ReadingHistory.points([reading(60 * 25, 140)], window: .twentyFourHours, now: noon).isEmpty)
    }

    func testAWindowShowsItsHoursOldestFirst() {
        let readings = [reading(0, 1), reading(170, 2), reading(181, 3), reading(359, 4), reading(361, 5), reading(700, 6), reading(1400, 7), reading(1441, 8)]
        XCTAssertEqual(ReadingHistory.points(readings, window: .threeHours, now: noon).map(\.mgdl), [2, 1])
        XCTAssertEqual(ReadingHistory.points(readings, window: .sixHours, now: noon).map(\.mgdl), [4, 3, 2, 1])
        XCTAssertEqual(ReadingHistory.points(readings, window: .twelveHours, now: noon).map(\.mgdl), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(ReadingHistory.points(readings, window: .twentyFourHours, now: noon).map(\.mgdl), [7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(CurveWindow.allCases.map(\.hours), [3, 6, 12, 24])
        XCTAssertEqual(CurveWindow.allCases.map(\.axisStrideHours), [1, 1, 3, 6])
    }

    func testTheAxisCoversReadingsAndTargetRangeOnTwentySteps() {
        let t = GlucoseThresholds.nightscoutDefaults
        XCTAssertEqual(ReadingHistory.yDomainMgdl([], thresholds: t), 60...200)
        XCTAssertEqual(ReadingHistory.yDomainMgdl([reading(0, 45), reading(5, 251)], thresholds: t), 20...280)
        // Every reading the parser accepts (up to 720 mg/dL) stays on the chart.
        XCTAssertEqual(ReadingHistory.yDomainMgdl([reading(0, 720)], thresholds: t), 60...740)
    }

    func testRefreshesAroundTheExpectedNextReading() {
        XCTAssertEqual(RefreshSchedule.delay(newest: nil, now: noon), 30)
        // Read 1 min ago: the next is due in 4 min.
        XCTAssertEqual(RefreshSchedule.delay(newest: reading(1, 100), now: noon), 240)
        // Due in 20 s or overdue: every 30 s until it arrives.
        XCTAssertEqual(RefreshSchedule.delay(newest: reading(4.67, 100), now: noon), 30)
        XCTAssertEqual(RefreshSchedule.delay(newest: reading(25, 100), now: noon), 30)
        // A reading from the future never means waiting longer than one interval.
        XCTAssertEqual(RefreshSchedule.delay(newest: reading(-10, 100), now: noon), 300)
    }
}

final class SetupTests: XCTestCase {
    func testAcceptsAnAddressAndToken() {
        XCTAssertEqual(
            Setup.validate(site: " ns.example.org/ ", token: " fixture-token "),
            .success(.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token"))
        )
    }

    func testSaysWhatIsMissing() {
        XCTAssertEqual(Setup.validate(site: "  ", token: "x"), .failure(.missingAddress))
        XCTAssertEqual(Setup.validate(site: "http://ns.example.org", token: "x"), .failure(.notHTTPS))
        XCTAssertEqual(Setup.validate(site: "https://", token: "x"), .failure(.invalidAddress))
        XCTAssertEqual(Setup.validate(site: "ns.example.org?token=x", token: "x"), .failure(.invalidAddress))
        XCTAssertEqual(Setup.validate(site: "ns.example.org", token: "  "), .failure(.missingToken))
    }

    func testAScannedCodeMustBeAFollowLink() throws {
        let link = FollowLink(site: URL(string: "https://ns.example.org")!, token: "fixture-token")
        XCTAssertEqual(Setup.parseScanned(" \(link.url().absoluteString)\n"), .success(link))
        XCTAssertEqual(Setup.parseScanned("https://ns.example.org"), .failure(.notAFollowLink))
        XCTAssertEqual(Setup.parseScanned("hello"), .failure(.notAFollowLink))
    }

    func testStoresAndRestoresTheSource() {
        let site = FollowSource.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token")
        let stored = site.stored
        XCTAssertEqual(FollowSource.restore(site: stored.site, token: stored.token), site)
        XCTAssertEqual(FollowSource.restore(site: FollowSource.demo.stored.site, token: FollowSource.demo.stored.token), .demo)
        XCTAssertNil(FollowSource.restore(site: nil, token: nil))
        XCTAssertNil(FollowSource.restore(site: "https://ns.example.org", token: ""))
        XCTAssertEqual(site.displayHost, "ns.example.org")
        XCTAssertNil(FollowSource.demo.relayToken)
    }

    func testTheConnectionTestReadsOneEntry() async throws {
        let body = Data(#"[{"sgv":120,"date":1793016000000,"direction":"Flat"}]"#.utf8)
        let transport = StubTransport(body: body)
        let feed = ReadingFeed(client: NightscoutClient(transport: transport))
        let source = FollowSource.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token")
        let result = await feed.test(source)
        XCTAssertEqual(try result.get()?.mgdl, 120)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://ns.example.org/api/v1/entries/sgv.json?count=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "fixture-token")
    }

    func testTheConnectionTestReportsARefusedToken() async {
        let feed = ReadingFeed(client: NightscoutClient(transport: StubTransport(status: 401)))
        let source = FollowSource.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token")
        let result = await feed.test(source)
        XCTAssertEqual(result, .failure(.tokenRefused))
    }

    func testAnEmptySiteStillConnects() async {
        let feed = ReadingFeed(client: NightscoutClient(transport: StubTransport(body: Data("[]".utf8))))
        let source = FollowSource.nightscout(site: URL(string: "https://ns.example.org")!, token: "fixture-token")
        let result = await feed.test(source)
        XCTAssertEqual(result, .success(nil))
    }
}

final class FollowSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = FollowSettings.load(nil)
        XCTAssertEqual(settings.unit, .mmolL)
        XCTAssertTrue(settings.liveActivityOn, "on by default after onboarding")
        XCTAssertFalse(settings.alertsOn, "off until the user allows notifications")
        XCTAssertEqual(settings.curveWindow, .sixHours)
    }

    func testRoundTrips() {
        let settings = FollowSettings(unit: .mgdL, liveActivityOn: false, alertsOn: true, curveWindow: .twelveHours)
        XCTAssertEqual(FollowSettings.load(settings.encoded()), settings)
        // A copy from a build that had "Start Live Activity automatically" still loads; the old
        // switch is ignored, so a phone that had it off now keeps one showing.
        let old = FollowSettings.load(Data(#"{"liveActivityOn":true,"autoStartLiveActivity":false,"unit":"mgdL"}"#.utf8))
        XCTAssertTrue(old.liveActivityOn)
        XCTAssertEqual(old.unit, .mgdL)
        XCTAssertFalse(String(decoding: old.encoded(), as: UTF8.self).contains("autoStart"))
    }

    func testAPartOrDamagedCopyFallsBackField() {
        XCTAssertEqual(FollowSettings.load(Data(#"{"unit":"mgdL"}"#.utf8)).unit, .mgdL)
        XCTAssertTrue(FollowSettings.load(Data(#"{"unit":"mgdL"}"#.utf8)).liveActivityOn)
        XCTAssertEqual(FollowSettings.load(Data(#"{"unit":"furlongs","curveWindow":5}"#.utf8)), .defaults)
        XCTAssertEqual(FollowSettings.load(Data("nonsense".utf8)), .defaults)
    }
}

final class LiveActivitySyncTests: XCTestCase {
    func state(_ minutesAgo: Double, _ mgdl: Int) -> LiveGlucoseState {
        LiveGlucoseState(current: reading(minutesAgo, mgdl), previous: nil)
    }

    func testANewerReadingReplacesTheActivity() {
        XCTAssertTrue(LiveActivitySync.shouldReplace(state(5, 130), with: state(0, 125)))
        XCTAssertTrue(LiveActivitySync.shouldReplace(nil, with: state(0, 125)))
    }

    func testTheSameOrAnOlderReadingNeverDoes() {
        // A late local fetch must not overwrite what the relay pushed.
        XCTAssertFalse(LiveActivitySync.shouldReplace(state(0, 124), with: state(5, 130)))
        XCTAssertFalse(LiveActivitySync.shouldReplace(state(0, 124), with: state(0, 124)))
        XCTAssertFalse(LiveActivitySync.shouldReplace(state(0, 124), with: state(0, 130)))
    }

    typealias Running = LiveActivitySync.RunningActivity

    func autoStart(
        liveActivityOn: Bool = true, systemAllows: Bool = true,
        running: [Running] = [], haveReading: Bool = true
    ) -> LiveActivitySync.AutoStart {
        LiveActivitySync.autoStart(
            liveActivityOn: liveActivityOn, systemAllows: systemAllows,
            running: running, haveReading: haveReading
        )
    }

    func testStartsWhenNothingRuns() {
        XCTAssertEqual(autoStart(), .start)
    }

    func testStartsOnlyWhenEverythingAllowsIt() {
        XCTAssertEqual(autoStart(liveActivityOn: false), .nothing)
        XCTAssertEqual(autoStart(systemAllows: false), .nothing)
        XCTAssertEqual(autoStart(haveReading: false), .nothing)
    }

    func testReusesARunningActivityInsteadOfADuplicate() {
        let one = Running(id: "a", startedAt: noon)
        XCTAssertEqual(autoStart(running: [one]), .reuse(keep: "a", end: []))
    }

    func testKeepsTheNewestAndEndsTheRest() {
        let running = [
            Running(id: "old", startedAt: noon.addingTimeInterval(-8 * 3600)),
            Running(id: "new", startedAt: noon),
            Running(id: "mid", startedAt: noon.addingTimeInterval(-3600)),
        ]
        XCTAssertEqual(autoStart(running: running), .reuse(keep: "new", end: ["mid", "old"]))
    }

    func testLeavesActivitiesAloneWhenSwitchedOff() {
        XCTAssertEqual(autoStart(liveActivityOn: false, running: [Running(id: "a", startedAt: noon)]), .nothing)
    }

    func testStatus() {
        XCTAssertEqual(LiveActivitySync.status(wanted: false, running: true), .off)
        XCTAssertEqual(LiveActivitySync.status(wanted: true, running: true), .running)
        XCTAssertEqual(LiveActivitySync.status(wanted: true, running: false), .stopped)
    }
}
