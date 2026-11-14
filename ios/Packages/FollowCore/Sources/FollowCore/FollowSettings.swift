import Foundation

/// The user's choices, kept as JSON in the app group. Anything missing or unreadable falls back to
/// its default, so an older or damaged copy never stops the app from starting.
public struct FollowSettings: Codable, Equatable, Sendable {
    /// mmol/L unless the user picks mg/dL.
    public var unit: GlucoseUnit
    /// On by default after onboarding (plan §3). On means one is always showing: the app starts one
    /// at launch and on every return to the foreground when none is running.
    public var liveActivityOn: Bool
    /// Off until the user turns it on and allows notifications.
    public var alertsOn: Bool
    public var curveWindow: CurveWindow
    /// How many days the reservoir and the site last before the countdown says they are due.
    public var cartridgeDays: Int
    public var cannulaDays: Int

    public static let defaults = FollowSettings(unit: .mmolL, liveActivityOn: true, alertsOn: false, curveWindow: .sixHours)

    public init(
        unit: GlucoseUnit, liveActivityOn: Bool, alertsOn: Bool, curveWindow: CurveWindow,
        cartridgeDays: Int = PumpCountdown.defaultDays, cannulaDays: Int = PumpCountdown.defaultDays
    ) {
        self.unit = unit
        self.liveActivityOn = liveActivityOn
        self.alertsOn = alertsOn
        self.curveWindow = curveWindow
        self.cartridgeDays = Self.clampDays(cartridgeDays)
        self.cannulaDays = Self.clampDays(cannulaDays)
    }

    /// The interval for one part.
    public func days(for part: PumpPart) -> Int {
        part == .cartridge ? cartridgeDays : cannulaDays
    }

    public mutating func setDays(_ days: Int, for part: PumpPart) {
        switch part {
        case .cartridge: cartridgeDays = Self.clampDays(days)
        case .cannula: cannulaDays = Self.clampDays(days)
        }
    }

    static func clampDays(_ days: Int) -> Int {
        min(max(days, PumpCountdown.dayChoices.lowerBound), PumpCountdown.dayChoices.upperBound)
    }

    /// A copy saved by an earlier build may still hold `autoStartLiveActivity`; it is ignored.
    private enum CodingKeys: String, CodingKey {
        case unit, liveActivityOn, alertsOn, curveWindow, cartridgeDays, cannulaDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        unit = (try? container.decodeIfPresent(GlucoseUnit.self, forKey: .unit)) ?? fallback.unit
        liveActivityOn = (try? container.decodeIfPresent(Bool.self, forKey: .liveActivityOn)) ?? fallback.liveActivityOn
        alertsOn = (try? container.decodeIfPresent(Bool.self, forKey: .alertsOn)) ?? fallback.alertsOn
        curveWindow = (try? container.decodeIfPresent(CurveWindow.self, forKey: .curveWindow)) ?? fallback.curveWindow
        cartridgeDays = Self.clampDays((try? container.decodeIfPresent(Int.self, forKey: .cartridgeDays)) ?? fallback.cartridgeDays)
        cannulaDays = Self.clampDays((try? container.decodeIfPresent(Int.self, forKey: .cannulaDays)) ?? fallback.cannulaDays)
    }

    /// The stored copy, or the defaults when there is none or it cannot be read.
    public static func load(_ data: Data?) -> FollowSettings {
        guard let data, let settings = try? JSONDecoder().decode(FollowSettings.self, from: data) else { return defaults }
        return settings
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
