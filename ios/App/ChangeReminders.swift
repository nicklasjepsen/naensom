import Combine
import FollowCore
import Foundation
import UserNotifications

/// The change reminders (`ChangeReminders` in FollowCore): a notification when the reservoir, the
/// site or the sensor is due, scheduled on the phone from the changes the app has read, with four
/// snooze actions. Nothing here goes through the relay, so it also works for a phone the relay
/// does not know. An ordinary notification: it follows silent mode and Focus.
@MainActor
final class ChangeReminderController: ObservableObject {
    static let shared = ChangeReminderController()

    static let category = "change-reminder"
    private static let snoozePrefix = "snooze."
    private static let storeKey = "changeSnoozes"

    /// The reminders put off, by part, for the screen ("Reminds again 14.30").
    @Published private(set) var snoozes: [PumpPart: ChangeSnooze] = ChangeReminderController.load()

    private var center: UNUserNotificationCenter { .current() }

    /// The snooze actions, registered once at every start of the process: iOS shows them when a
    /// reminder is held down, and runs the app in the background for the one that is tapped.
    static func registerCategory() {
        let actions = ChangeSnoozeChoice.allCases.map { choice in
            UNNotificationAction(identifier: snoozePrefix + choice.rawValue, title: label(choice), options: [])
        }
        let category = UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Brings what is waiting in line with the changes just read. Without changes (nothing read
    /// yet in this run of the app) it leaves what is waiting alone; with the reminders off
    /// everything goes at once, read or not, so turning them off never waits for the site.
    func sync(changes: PumpChanges?, settings: FollowSettings, now: Date = Date()) {
        guard settings.changeRemindersOn else {
            clear()
            return
        }
        guard let changes else { return }
        let kept = ChangeReminders.kept(snoozes, changes: changes)
        if kept != snoozes { store(kept) }
        let plan = ChangeReminders.plan(changes: changes, settings: settings, snoozes: snoozes, now: now)
        let waiting = Set(plan.map(\.part))
        let current = ChangeReminders.current(changes: changes, settings: settings, snoozes: snoozes, now: now)
        center.removePendingNotificationRequests(
            withIdentifiers: PumpPart.allCases.filter { !waiting.contains($0) }.map(Self.identifier)
        )
        center.removeDeliveredNotifications(
            withIdentifiers: PumpPart.allCases.filter { !current.contains($0) }.map(Self.identifier)
        )
        for reminder in plan { schedule(reminder, now: now) }
    }

    /// Puts a part's reminder off, from the app or from the notification's action. It comes back
    /// when the time is up unless the part was changed meanwhile.
    func snooze(_ part: PumpPart, lastAt: Date, for choice: ChangeSnoozeChoice, now: Date = Date()) {
        let until = now.addingTimeInterval(choice.interval)
        var next = snoozes
        next[part] = ChangeSnooze(lastAt: lastAt, until: until)
        store(next)
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(part)])
        schedule(ChangeReminder(part: part, lastAt: lastAt, fireAt: until), now: now)
    }

    /// A tapped snooze action. Answers whether the response was one.
    @discardableResult
    func handle(action: String, part: String?, lastAt: Double?) -> Bool {
        guard action.hasPrefix(Self.snoozePrefix),
              let choice = ChangeSnoozeChoice(rawValue: String(action.dropFirst(Self.snoozePrefix.count))),
              let part = part.flatMap(PumpPart.init(rawValue:)),
              let lastAt
        else { return false }
        snooze(part, lastAt: Date(timeIntervalSince1970: lastAt), for: choice)
        return true
    }

    /// "Remove this phone": nothing waits, nothing stays on the lock screen, nothing is remembered.
    func clear() {
        let all = PumpPart.allCases.map(Self.identifier)
        center.removePendingNotificationRequests(withIdentifiers: all)
        center.removeDeliveredNotifications(withIdentifiers: all)
        if !snoozes.isEmpty { store([:]) }
    }

    // MARK: - Pieces

    /// One request per part: a new one replaces the one waiting.
    private func schedule(_ reminder: ChangeReminder, now: Date) {
        let content = UNMutableNotificationContent()
        content.title = Self.title(reminder.part)
        content.body = L("changes.last", Self.time(reminder.lastAt))
        content.sound = .default
        content.threadIdentifier = "changes"
        content.categoryIdentifier = Self.category
        content.userInfo = ["part": reminder.part.rawValue, "lastAt": reminder.lastAt.timeIntervalSince1970]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, reminder.fireAt.timeIntervalSince(now)), repeats: false
        )
        center.add(UNNotificationRequest(identifier: Self.identifier(reminder.part), content: content, trigger: trigger))
    }

    private static func identifier(_ part: PumpPart) -> String { "change.\(part.rawValue)" }

    private static func title(_ part: PumpPart) -> String {
        switch part {
        case .cartridge: return L("reminder.change.cartridge")
        case .cannula: return L("reminder.change.cannula")
        case .sensor: return L("reminder.change.sensor")
        }
    }

    static func label(_ choice: ChangeSnoozeChoice) -> String {
        switch choice {
        case .tenMinutes: return L("reminder.snooze.tenMinutes")
        case .thirtyMinutes: return L("reminder.snooze.thirtyMinutes")
        case .twoHours: return L("reminder.snooze.twoHours")
        case .oneDay: return L("reminder.snooze.oneDay")
        }
    }

    /// "lør. 14. nov. 09.12" / "Sat 14 Nov 09:12" in the phone's own time zone.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(AppLanguage.locale))
    }

    private func store(_ next: [PumpPart: ChangeSnooze]) {
        snoozes = next
        let raw = Dictionary(uniqueKeysWithValues: next.map { ($0.key.rawValue, $0.value) })
        if raw.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storeKey)
        } else if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private static func load() -> [PumpPart: ChangeSnooze] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let raw = try? JSONDecoder().decode([String: ChangeSnooze].self, from: data)
        else { return [:] }
        var out: [PumpPart: ChangeSnooze] = [:]
        for (key, value) in raw {
            if let part = PumpPart(rawValue: key) { out[part] = value }
        }
        return out
    }
}
