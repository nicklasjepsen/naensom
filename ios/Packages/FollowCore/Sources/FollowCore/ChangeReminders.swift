import Foundation

/// How long a change reminder can be put off: the four choices on the notification and in the app.
public enum ChangeSnoozeChoice: String, CaseIterable, Sendable {
    case tenMinutes
    case thirtyMinutes
    case twoHours
    case oneDay

    public var interval: TimeInterval {
        switch self {
        case .tenMinutes: return 10 * 60
        case .thirtyMinutes: return 30 * 60
        case .twoHours: return 2 * 3600
        case .oneDay: return 86_400
        }
    }
}

/// A reminder that was put off: for the change the part had then, until a moment. A newer change
/// makes it meaningless, which is why it carries the change it was about.
public struct ChangeSnooze: Codable, Equatable, Sendable {
    public var lastAt: Date
    public var until: Date

    public init(lastAt: Date, until: Date) {
        self.lastAt = lastAt
        self.until = until
    }

    /// True while it still holds: about the part's newest change, and not yet over.
    public func holds(for lastAt: Date?, now: Date) -> Bool {
        guard let lastAt else { return false }
        return abs(lastAt.timeIntervalSince(self.lastAt)) < 1 && until > now
    }
}

/// One notification the phone should have waiting: for a part, about a change, at a moment.
public struct ChangeReminder: Equatable, Sendable {
    public var part: PumpPart
    /// The change it is about; the notification says when that was.
    public var lastAt: Date
    public var fireAt: Date

    public init(part: PumpPart, lastAt: Date, fireAt: Date) {
        self.part = part
        self.lastAt = lastAt
        self.fireAt = fireAt
    }
}

/// The change reminders: one notification when a part is due (its last change plus the days it
/// lasts), and again when a snooze the user chose is over. The phone schedules them itself from
/// the changes it has read; nothing is sent to the relay. A reminder, not an alarm: it says a
/// change is due and nothing about amounts.
public enum ChangeReminders {
    /// What should be waiting now. A part is in it when it is not due yet (the reminder waits for
    /// the due time), or when it is due and a snooze about this same change is still running (it
    /// waits for the snooze to end; a snooze reaching past a due time that moved later wins). A
    /// part that is already due without a snooze has had its reminder and gets none.
    public static func plan(
        changes: PumpChanges, settings: FollowSettings, snoozes: [PumpPart: ChangeSnooze], now: Date
    ) -> [ChangeReminder] {
        guard settings.changeRemindersOn else { return [] }
        return PumpPart.allCases.compactMap { part in
            guard let lastAt = changes[part],
                  let dueAt = PumpCountdown.dueAt(lastAt: lastAt, days: settings.days(for: part))
            else { return nil }
            let snoozedUntil = snoozes[part].flatMap { $0.holds(for: lastAt, now: now) ? $0.until : nil }
            let moments = [dueAt > now ? dueAt : nil, snoozedUntil].compactMap { $0 }
            guard let fireAt = moments.max() else { return nil }
            return ChangeReminder(part: part, lastAt: lastAt, fireAt: fireAt)
        }
    }

    /// The parts whose delivered reminder still says something true: reminders are on, the part is
    /// due, and it has not been put off. A delivered reminder for any other part is out of date
    /// (the part was changed, lasts longer now, or was snoozed) and is taken away.
    public static func current(
        changes: PumpChanges, settings: FollowSettings, snoozes: [PumpPart: ChangeSnooze], now: Date
    ) -> Set<PumpPart> {
        guard settings.changeRemindersOn else { return [] }
        return Set(PumpPart.allCases.filter { part in
            guard let lastAt = changes[part],
                  let dueAt = PumpCountdown.dueAt(lastAt: lastAt, days: settings.days(for: part)),
                  dueAt <= now
            else { return false }
            return !(snoozes[part]?.holds(for: lastAt, now: now) ?? false)
        })
    }

    /// The snoozes worth keeping: those about a part's newest change. One about an older change is
    /// dropped; one that is over stays until the next snooze replaces it and counts for nothing.
    public static func kept(_ snoozes: [PumpPart: ChangeSnooze], changes: PumpChanges) -> [PumpPart: ChangeSnooze] {
        snoozes.filter { part, snooze in
            guard let lastAt = changes[part] else { return false }
            return abs(lastAt.timeIntervalSince(snooze.lastAt)) < 1
        }
    }
}
