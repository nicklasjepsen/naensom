import Foundation

/// Decisions about the running Live Activity that do not need ActivityKit.
public enum LiveActivitySync {
    /// Whether a reading the app fetched should replace what the activity shows. While the app is
    /// open it updates the activity itself, so the two never disagree; but only with a newer
    /// reading, so a late local fetch never overwrites a newer state the relay pushed.
    public static func shouldReplace(_ shown: LiveGlucoseState?, with fresh: LiveGlucoseState) -> Bool {
        guard let shown else { return true }
        return fresh.readingAt > shown.readingAt
    }

    public enum Status: Equatable, Sendable {
        /// The user turned the Live Activity off.
        case off
        case running
        /// Wanted but not running: it ended (8 hours, the user swiped it away, push-to-start failed).
        /// The main screen says "Live Activity stopped, tap to restart" (plan §4).
        case stopped
    }

    public static func status(wanted: Bool, running: Bool) -> Status {
        if !wanted { return .off }
        return running ? .running : .stopped
    }

    /// A Live Activity the phone still shows: running (active or stale), or ended and not yet
    /// taken off the lock screen (iOS leaves an ended one there, grey, for up to four hours).
    public struct RunningActivity: Equatable, Sendable {
        public var id: String
        /// When the app started or first saw it.
        public var startedAt: Date
        /// The reading it shows, when the app could tell.
        public var readingAt: Date?
        /// False once it has ended: it still shows, but takes no more updates.
        public var isLive: Bool

        public init(id: String, startedAt: Date, readingAt: Date? = nil, isLive: Bool = true) {
            self.id = id
            self.startedAt = startedAt
            self.readingAt = readingAt
            self.isLive = isLive
        }
    }

    /// Which activity stays and which go, so the lock screen never shows two: the newest running
    /// one stays (the one seen last; of two first seen together, the one with the newer reading),
    /// and every other goes, running or ended. Nil when none is running: an ended one alone is
    /// left for a new start to replace.
    public static func tidy(_ shown: [RunningActivity]) -> (keep: String, end: [String])? {
        let newest = shown.filter(\.isLive).max {
            ($0.startedAt, $0.readingAt ?? .distantPast, $0.id) < ($1.startedAt, $1.readingAt ?? .distantPast, $1.id)
        }
        guard let newest else { return nil }
        return (newest.id, shown.filter { $0.id != newest.id }.map(\.id).sorted())
    }

    public enum AutoStart: Equatable, Sendable {
        /// Start a new activity with the newest reading.
        case start
        /// One is already running: keep it (the newest) and end any others, never a duplicate.
        case reuse(keep: String, end: [String])
        case nothing
    }

    /// What to do when the app launches or comes back to the foreground. With the Live Activity
    /// switched off nothing happens; a running one is reused (`tidy`: the newest kept, every other
    /// one the phone still shows ended); otherwise a new one starts whenever iOS allows Live
    /// Activities and there is a reading to show. "Live Activity" on means one is always there;
    /// there is no separate automatic switch.
    public static func autoStart(
        liveActivityOn: Bool, systemAllows: Bool, running: [RunningActivity], haveReading: Bool
    ) -> AutoStart {
        guard liveActivityOn else { return .nothing }
        if let plan = tidy(running) { return .reuse(keep: plan.keep, end: plan.end) }
        guard systemAllows, haveReading else { return .nothing }
        return .start
    }
}
