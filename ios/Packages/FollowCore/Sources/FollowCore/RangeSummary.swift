import Foundation

/// What the readings in one curve window add up to: the time in, above and below the target range,
/// the average, and the lowest and highest reading. Shown when the value on the main screen is
/// tapped. Figures about the past only: nothing here says what to do.
///
/// Counted by time, never by the number of readings: a reading stands for the time until the next
/// one, at most `maxHold`. A site that stores every reading twice (a phone and a watch on one
/// sensor) or uploads every minute therefore gets the same answer as one reading per five minutes,
/// and a gap in the readings counts as nothing and not as more of the last value.
public struct RangeSummary: Equatable, Sendable {
    /// The longest one reading stands for: one missed reading on a five-minute sensor is bridged,
    /// a longer gap is left out.
    public static let maxHold: TimeInterval = 10 * 60
    /// Under this share of the window, the summary says how much time it builds on.
    public static let fullCoverage = 0.9

    /// The three shares the summary names. The two urgent bands are part of below and above.
    public enum Part: String, CaseIterable, Sendable {
        case below, inTarget, above
    }

    /// The length of the window asked for.
    public let window: TimeInterval
    /// The time each band was held; a band never seen is absent.
    public let seconds: [GlucoseBand: TimeInterval]
    /// The average over the covered time, in mg/dL; nil without readings.
    public let averageMgdl: Int?
    /// The lowest and highest reading; the earliest of each when a value repeats.
    public let lowest: Reading?
    public let highest: Reading?

    public init(_ readings: [Reading], window: CurveWindow, thresholds: GlucoseThresholds, now: Date) {
        let points = ReadingHistory.points(readings, window: window, now: now)
        var seconds: [GlucoseBand: TimeInterval] = [:]
        var weighted = 0.0
        for (index, reading) in points.enumerated() {
            let until = index + 1 < points.count ? points[index + 1].at : now
            let held = min(max(until.timeIntervalSince(reading.at), 0), Self.maxHold)
            seconds[Glucose.band(reading.mgdl, thresholds: thresholds), default: 0] += held
            weighted += Double(reading.mgdl) * held
        }
        let covered = seconds.values.reduce(0, +)
        self.window = window.duration
        self.seconds = seconds.filter { $0.value > 0 }
        self.averageMgdl = covered > 0 ? Int((weighted / covered).rounded()) : nil
        // Only a reading that counted: one at this very moment has held no time yet.
        self.lowest = covered > 0 ? points.min { $0.mgdl < $1.mgdl } : nil
        self.highest = covered > 0 ? points.max { $0.mgdl < $1.mgdl } : nil
    }

    /// The time the readings account for.
    public var covered: TimeInterval { seconds.values.reduce(0, +) }

    public var isEmpty: Bool { covered <= 0 }

    /// False when the readings leave a noticeable part of the window out (a sensor change, a phone
    /// out of reach, a site followed for less than the window).
    public var isComplete: Bool { covered >= window * Self.fullCoverage }

    public func seconds(_ part: Part) -> TimeInterval {
        switch part {
        case .below: return (seconds[.urgentLow] ?? 0) + (seconds[.low] ?? 0)
        case .inTarget: return seconds[.inRange] ?? 0
        case .above: return (seconds[.high] ?? 0) + (seconds[.urgentHigh] ?? 0)
        }
    }

    /// The share of the covered time in one band, 0...1, for drawing.
    public func fraction(_ band: GlucoseBand) -> Double {
        isEmpty ? 0 : (seconds[band] ?? 0) / covered
    }

    /// Whole percentages of the covered time that always add up to 100 (largest remainders get the
    /// spare points), and never 0 for a part that was there: under half a percent reads as 1.
    public var percentages: [Part: Int] {
        guard !isEmpty else { return [:] }
        let exact = Part.allCases.map { (part: $0, value: seconds($0) / covered * 100) }
        var whole = Dictionary(uniqueKeysWithValues: exact.map { ($0.part, Int($0.value.rounded(.down))) })
        let spare = 100 - whole.values.reduce(0, +)
        let byRemainder = exact.sorted { $0.value - $0.value.rounded(.down) > $1.value - $1.value.rounded(.down) }
        for entry in byRemainder.prefix(max(spare, 0)) { whole[entry.part, default: 0] += 1 }
        for entry in exact where entry.value > 0 && whole[entry.part] == 0 {
            guard let largest = whole.max(by: { $0.value < $1.value })?.key else { break }
            whole[entry.part] = 1
            whole[largest, default: 0] -= 1
        }
        return whole
    }

    /// "45 min", "1 h 20 min", "3 h" (Danish: "1 t 20 min"). Rounded to the minute; anything
    /// under a minute that is not nothing reads "1 min".
    public static func durationText(_ seconds: TimeInterval, language: Language = .en) -> String {
        let total = seconds > 0 ? max(1, Int((seconds / 60).rounded())) : 0
        let hours = total / 60
        let minutes = total % 60
        let h = language == .da ? "t" : "h"
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) \(h)" }
        return "\(hours) \(h) \(minutes) min"
    }
}
