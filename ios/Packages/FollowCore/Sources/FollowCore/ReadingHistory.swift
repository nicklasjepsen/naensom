import Foundation

/// How much of the curve the main screen shows.
public enum CurveWindow: Int, Codable, CaseIterable, Sendable {
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    public var hours: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue) * 3600 }
    /// Hours between the time labels under the curve, so they never crowd: hourly up to 6 hours,
    /// every 3 hours at 12, every 6 hours at 24.
    public var axisStrideHours: Int {
        switch self {
        case .threeHours, .sixHours: return 1
        case .twelveHours: return 3
        case .twentyFourHours: return 6
        }
    }
}

/// The readings the app keeps while it is open: the last 24 hours, newest first, one per
/// timestamp. Fetched in full once, then topped up with the readings since the newest.
public enum ReadingHistory {
    /// The longest curve the app shows.
    public static let keep: TimeInterval = CurveWindow.twentyFourHours.duration
    /// The most readings one fetch asks for: twenty-four hours of a site that uploads every minute,
    /// stored twice over. A cap only; the site sends what it holds for the time asked.
    public static let fetchLimit = 3000

    /// The moment to read from: the whole twenty-four hours when there is no history (or none that
    /// recent), otherwise the newest reading on. Always a time, never a count of the readings
    /// expected since: a site with a phone and a watch on one sensor stores every reading twice, so
    /// "one per five minutes" covered half the time away and left a hole in the curve.
    public static func fetchStart(newest: Reading?, now: Date) -> Date {
        let oldest = now.addingTimeInterval(-keep)
        guard let newest, newest.at > oldest else { return oldest }
        return newest.at
    }

    /// Old and new together, newest first, one per timestamp (the fresh copy wins), older than
    /// twenty-four hours dropped, except the newest reading: a site that has sent nothing for longer
    /// still shows its last value, grey and with its age.
    public static func merge(_ existing: [Reading], _ fresh: [Reading], now: Date) -> [Reading] {
        var byTime: [Date: Reading] = [:]
        for reading in existing { byTime[reading.at] = reading }
        for reading in fresh { byTime[reading.at] = reading }
        let sorted = byTime.values.sorted { $0.at > $1.at }
        let oldest = now.addingTimeInterval(-keep)
        return sorted.enumerated().filter { $0.offset == 0 || $0.element.at >= oldest }.map(\.element)
    }

    /// The readings a curve window shows, oldest first, as a chart draws them.
    public static func points(_ readings: [Reading], window: CurveWindow, now: Date) -> [Reading] {
        let start = now.addingTimeInterval(-window.duration)
        return readings.filter { $0.at >= start && $0.at <= now }.sorted { $0.at < $1.at }
    }

    /// The curve's vertical range in mg/dL: the readings and the target range, with a little room,
    /// on 20 mg/dL steps so the axis does not jump with every reading.
    public static func yDomainMgdl(_ readings: [Reading], thresholds: GlucoseThresholds) -> ClosedRange<Int> {
        let values = readings.map(\.mgdl)
        let low = min(values.min() ?? thresholds.lowMgdl, thresholds.lowMgdl) - 10
        let high = max(values.max() ?? thresholds.highMgdl, thresholds.highMgdl) + 10
        let bottom = max(0, Int((Double(low) / 20).rounded(.down)) * 20)
        let top = Int((Double(high) / 20).rounded(.up)) * 20
        return bottom...max(top, bottom + 40)
    }
}

/// When the app reads again while it is on screen (plan §3): nothing until the next reading is
/// due (the newest + 5 minutes), then every 30 seconds until it arrives.
public enum RefreshSchedule {
    public static let expectedInterval: TimeInterval = 300
    public static let pollInterval: TimeInterval = 30

    public static func delay(newest: Reading?, now: Date) -> TimeInterval {
        guard let newest else { return pollInterval }
        let untilDue = newest.at.addingTimeInterval(expectedInterval).timeIntervalSince(now)
        return min(expectedInterval, max(pollInterval, untilDue))
    }
}
