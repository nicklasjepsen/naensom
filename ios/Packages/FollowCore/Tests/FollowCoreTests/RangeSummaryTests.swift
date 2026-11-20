import Foundation
import XCTest
@testable import FollowCore

final class RangeSummaryTests: XCTestCase {
    let t = GlucoseThresholds.nightscoutDefaults
    let now = Date(timeIntervalSince1970: 1_793_016_000)

    /// One reading every `step` seconds, the first `minutesAgo` back, oldest first.
    private func series(_ values: [Int], startMinutesAgo: Double, step: TimeInterval = 300) -> [Reading] {
        values.enumerated().map { index, mgdl in
            Reading(at: now.addingTimeInterval(-startMinutesAgo * 60 + Double(index) * step), mgdl: mgdl, direction: "Flat")
        }
    }

    func testSharesByTimeOverAFullWindow() {
        // Three hours, one reading per five minutes: 18 in target, 12 above, 6 below.
        let values = Array(repeating: 120, count: 18) + Array(repeating: 200, count: 12) + Array(repeating: 70, count: 6)
        let summary = RangeSummary(series(values, startMinutesAgo: 180), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(summary.covered, 3 * 3600, accuracy: 0.001)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.percentages, [.inTarget: 50, .above: 33, .below: 17])
        XCTAssertEqual(summary.seconds(.above), 3600, accuracy: 0.001)
        XCTAssertEqual(summary.averageMgdl, 138)
    }

    func testEveryReadingStoredTwiceChangesNothing() {
        let values = Array(repeating: 120, count: 18) + Array(repeating: 200, count: 18)
        let once = series(values, startMinutesAgo: 180)
        // The second copy a few seconds later, as a phone and a watch on one sensor upload it; only
        // the readings in target are doubled, which would tip a count of readings.
        let copies = once.filter { $0.mgdl == 120 }.map { Reading(at: $0.at.addingTimeInterval(7), mgdl: $0.mgdl, direction: $0.direction) }
        let single = RangeSummary(once, window: .threeHours, thresholds: t, now: now)
        let doubled = RangeSummary(once + copies, window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(doubled.percentages, single.percentages)
        XCTAssertEqual(doubled.percentages[.inTarget], 50)
        XCTAssertEqual(doubled.averageMgdl, single.averageMgdl)
    }

    func testAGapCountsAsNothing() {
        // Readings for the first and the last half hour of three hours, nothing between.
        let early = series(Array(repeating: 200, count: 6), startMinutesAgo: 180)
        let late = series(Array(repeating: 120, count: 6), startMinutesAgo: 30)
        let summary = RangeSummary(early + late, window: .threeHours, thresholds: t, now: now)
        // The last early reading stands for ten minutes, not for the two hours that follow it.
        let expected: TimeInterval = 65 * 60 // 25 + 10 early, 30 late
        XCTAssertEqual(summary.covered, expected, accuracy: 0.001)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.percentages[.inTarget], 46)
        XCTAssertEqual(summary.percentages[.above], 54)
    }

    func testTheNewestReadingStandsUntilNowAtMostTenMinutes() {
        let fresh = RangeSummary(series([120], startMinutesAgo: 3), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(fresh.covered, 180, accuracy: 0.001)
        let old = RangeSummary(series([120], startMinutesAgo: 60), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(old.covered, RangeSummary.maxHold, accuracy: 0.001)
    }

    func testOnlyTheWindowCounts() {
        let values = Array(repeating: 300, count: 36) + Array(repeating: 120, count: 36)
        let summary = RangeSummary(series(values, startMinutesAgo: 360), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(summary.percentages, [.inTarget: 100, .above: 0, .below: 0])
        XCTAssertEqual(summary.highest?.mgdl, 120)
    }

    func testUrgentBandsBelongToBelowAndAbove() {
        let values = Array(repeating: 50, count: 6) + Array(repeating: 70, count: 6) + Array(repeating: 120, count: 12)
            + Array(repeating: 200, count: 6) + Array(repeating: 300, count: 6)
        let summary = RangeSummary(series(values, startMinutesAgo: 180), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(summary.seconds[.urgentLow] ?? 0, 1800, accuracy: 0.001)
        XCTAssertEqual(summary.seconds(.below), 3600, accuracy: 0.001)
        XCTAssertEqual(summary.seconds(.above), 3600, accuracy: 0.001)
        XCTAssertEqual(summary.fraction(.urgentHigh), 1.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(summary.percentages.values.reduce(0, +), 100)
    }

    func testLowestAndHighestWithTheirTimes() {
        let readings = series([120, 64, 150, 231, 231, 110], startMinutesAgo: 30)
        let summary = RangeSummary(readings, window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(summary.lowest, readings[1])
        XCTAssertEqual(summary.highest, readings[3], "the earliest of a repeated value")
    }

    func testPercentagesAddUpAndNeverHideAShortLow() {
        // 5 minutes low in 24 hours is 0.35 %: it reads 1, not 0.
        let values = Array(repeating: 120, count: 287) + [70]
        let summary = RangeSummary(series(values, startMinutesAgo: 1440), window: .twentyFourHours, thresholds: t, now: now)
        XCTAssertEqual(summary.percentages, [.inTarget: 99, .above: 0, .below: 1])
        // Thirds: 33.3 each becomes 34 + 33 + 33.
        let thirds = Array(repeating: 70, count: 12) + Array(repeating: 120, count: 12) + Array(repeating: 200, count: 12)
        let even = RangeSummary(series(thirds, startMinutesAgo: 180), window: .threeHours, thresholds: t, now: now)
        XCTAssertEqual(even.percentages.values.reduce(0, +), 100)
        XCTAssertEqual(even.percentages.values.sorted(), [33, 33, 34])
    }

    func testEmpty() {
        let summary = RangeSummary([], window: .sixHours, thresholds: t, now: now)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertFalse(summary.isComplete)
        XCTAssertNil(summary.averageMgdl)
        XCTAssertNil(summary.lowest)
        XCTAssertEqual(summary.percentages, [:])
        XCTAssertEqual(summary.fraction(.inRange), 0)
        // A reading at this very moment has held no time yet.
        XCTAssertTrue(RangeSummary(series([120], startMinutesAgo: 0), window: .sixHours, thresholds: t, now: now).isEmpty)
    }

    func testDurationText() {
        XCTAssertEqual(RangeSummary.durationText(0), "0 min")
        XCTAssertEqual(RangeSummary.durationText(20), "1 min")
        XCTAssertEqual(RangeSummary.durationText(45 * 60), "45 min")
        XCTAssertEqual(RangeSummary.durationText(3600), "1 h")
        XCTAssertEqual(RangeSummary.durationText(80 * 60), "1 h 20 min")
        XCTAssertEqual(RangeSummary.durationText(80 * 60, language: .da), "1 t 20 min")
        XCTAssertEqual(RangeSummary.durationText(3 * 3600, language: .da), "3 t")
    }
}
