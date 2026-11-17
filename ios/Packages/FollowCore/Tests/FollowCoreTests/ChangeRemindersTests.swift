import XCTest
@testable import FollowCore

final class ChangeRemindersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private var on: FollowSettings {
        var settings = FollowSettings.defaults
        settings.changeRemindersOn = true
        return settings
    }

    private func ago(_ interval: TimeInterval) -> Date { now.addingTimeInterval(-interval) }

    func testOffByDefaultAndKeptWhenSaved() {
        XCTAssertFalse(FollowSettings.defaults.changeRemindersOn)
        XCTAssertFalse(FollowSettings.load(Data(#"{"alertsOn":true}"#.utf8)).changeRemindersOn)
        XCTAssertTrue(FollowSettings.load(on.encoded()).changeRemindersOn)
    }

    func testTheFourSnoozeChoices() {
        XCTAssertEqual(ChangeSnoozeChoice.allCases.map(\.interval), [600, 1800, 7200, 86_400])
    }

    func testAPartNotYetDueWaitsForItsDueTime() {
        let changes = PumpChanges(cartridgeAt: ago(2 * day), cannulaAt: ago(1 * day), sensorAt: ago(4 * day))
        let plan = ChangeReminders.plan(changes: changes, settings: on, snoozes: [:], now: now)
        XCTAssertEqual(plan, [
            ChangeReminder(part: .cartridge, lastAt: ago(2 * day), fireAt: now.addingTimeInterval(1 * day)),
            ChangeReminder(part: .cannula, lastAt: ago(1 * day), fireAt: now.addingTimeInterval(2 * day)),
            ChangeReminder(part: .sensor, lastAt: ago(4 * day), fireAt: now.addingTimeInterval(6 * day)),
        ])
        XCTAssertEqual(ChangeReminders.current(changes: changes, settings: on, snoozes: [:], now: now), [])
    }

    func testNothingWaitsWhenRemindersAreOff() {
        let changes = PumpChanges(cartridgeAt: ago(2 * day), cannulaAt: ago(4 * day))
        XCTAssertEqual(ChangeReminders.plan(changes: changes, settings: .defaults, snoozes: [:], now: now), [])
        XCTAssertEqual(ChangeReminders.current(changes: changes, settings: .defaults, snoozes: [:], now: now), [])
    }

    func testAPartAlreadyDueHasHadItsReminder() {
        let changes = PumpChanges(cartridgeAt: ago(3 * day + 3600))
        XCTAssertEqual(ChangeReminders.plan(changes: changes, settings: on, snoozes: [:], now: now), [])
        XCTAssertEqual(ChangeReminders.current(changes: changes, settings: on, snoozes: [:], now: now), [.cartridge])
    }

    func testAPartThePumpNeverSentGetsNone() {
        XCTAssertEqual(ChangeReminders.plan(changes: PumpChanges(), settings: on, snoozes: [:], now: now), [])
    }

    func testASnoozedPartComesBackWhenTheSnoozeEnds() {
        let lastAt = ago(3 * day + 3600)
        let changes = PumpChanges(cannulaAt: lastAt)
        for choice in ChangeSnoozeChoice.allCases {
            let until = now.addingTimeInterval(choice.interval)
            let snoozes = [PumpPart.cannula: ChangeSnooze(lastAt: lastAt, until: until)]
            XCTAssertEqual(
                ChangeReminders.plan(changes: changes, settings: on, snoozes: snoozes, now: now),
                [ChangeReminder(part: .cannula, lastAt: lastAt, fireAt: until)]
            )
            // Put off: the reminder already on the lock screen goes.
            XCTAssertEqual(ChangeReminders.current(changes: changes, settings: on, snoozes: snoozes, now: now), [])
        }
    }

    func testASnoozeThatIsOverCountsForNothing() {
        let lastAt = ago(3 * day + 3600)
        let changes = PumpChanges(cannulaAt: lastAt)
        let snoozes = [PumpPart.cannula: ChangeSnooze(lastAt: lastAt, until: ago(60))]
        XCTAssertEqual(ChangeReminders.plan(changes: changes, settings: on, snoozes: snoozes, now: now), [])
        XCTAssertEqual(ChangeReminders.current(changes: changes, settings: on, snoozes: snoozes, now: now), [.cannula])
    }

    func testAChangeAfterTheSnoozeStartsOverFromTheNewChange() {
        let snoozes = [PumpPart.cartridge: ChangeSnooze(lastAt: ago(3 * day + 3600), until: now.addingTimeInterval(7200))]
        let changed = PumpChanges(cartridgeAt: ago(600))
        XCTAssertEqual(
            ChangeReminders.plan(changes: changed, settings: on, snoozes: snoozes, now: now),
            [ChangeReminder(part: .cartridge, lastAt: ago(600), fireAt: ago(600).addingTimeInterval(3 * day))]
        )
        XCTAssertEqual(ChangeReminders.kept(snoozes, changes: changed), [:])
        XCTAssertEqual(ChangeReminders.kept(snoozes, changes: PumpChanges(cartridgeAt: ago(3 * day + 3600))), snoozes)
        XCTAssertEqual(ChangeReminders.kept(snoozes, changes: PumpChanges()), [:])
    }

    func testASnoozeReachingPastALaterDueTimeWins() {
        // Snoozed for a day while due; then the part is set to last a day longer, due in 23 hours.
        let lastAt = ago(3 * day + 3600)
        var settings = on
        settings.setDays(4, for: .sensor)
        let until = now.addingTimeInterval(day)
        let plan = ChangeReminders.plan(
            changes: PumpChanges(sensorAt: lastAt), settings: settings,
            snoozes: [.sensor: ChangeSnooze(lastAt: lastAt, until: until)], now: now
        )
        XCTAssertEqual(plan, [ChangeReminder(part: .sensor, lastAt: lastAt, fireAt: until)])
    }

    func testSnoozesSurviveBeingSaved() throws {
        let snoozes = [PumpPart.cannula.rawValue: ChangeSnooze(lastAt: ago(day), until: now.addingTimeInterval(600))]
        let data = try JSONEncoder().encode(snoozes)
        XCTAssertEqual(try JSONDecoder().decode([String: ChangeSnooze].self, from: data), snoozes)
    }
}
