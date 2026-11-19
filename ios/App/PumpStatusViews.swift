import FollowCore
import SwiftUI

/// The pump's battery as a small battery symbol at the top of the main screen: filled as far as
/// the pump says it is charged, red under 20 percent, yellow under 50 and green from there. Colour
/// is never the only signal: the filling shows the level, VoiceOver reads the percent with its age,
/// and a tap shows both in words. Grey when the pump has said nothing for three hours; not shown
/// at all without a figure. Only in the app: the Live Activity and the widgets never show it.
struct PumpBatteryBadge: View {
    @EnvironmentObject private var follow: FollowModel
    @State private var showDetail = false

    var body: some View {
        if let battery = follow.pumpStatus?.battery {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                badge(battery, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func badge(_ battery: PumpFigure<Int>, now: Date) -> some View {
        let age = PumpStatus.age(of: battery.at, now: now, fresh: PumpStatus.batteryFresh, shown: PumpStatus.batteryShown)
        if age != .withheld {
            let words = L("pump.battery", battery.value)
            let ageText = Glucose.ageText(at: battery.at, now: now, language: AppLanguage.current)
            Button {
                showDetail = true
            } label: {
                BatteryGlyph(percent: battery.value, fill: age == .old ? .gray : Self.colour(battery.value))
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(words), \(ageText)")
            .popover(isPresented: $showDetail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(words).font(.subheadline.weight(.semibold))
                    Text(ageText).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// The same green, yellow and red as the glucose value.
    private static func colour(_ percent: Int) -> Color {
        switch PumpStatus.batteryLevel(percent: percent) {
        case .low: return GlucoseColor.red.color
        case .medium: return GlucoseColor.yellow.color
        case .good: return GlucoseColor.green.color
        }
    }
}

/// A battery drawn to the point: an outline, a filling as wide as the percent, and the terminal.
struct BatteryGlyph: View {
    let percent: Int
    let fill: Color

    private static let inset: CGFloat = 2.5

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.secondary, lineWidth: 1.5)
                GeometryReader { geometry in
                    let width = geometry.size.width - 2 * Self.inset
                    let share = CGFloat(min(max(percent, 0), 100)) / 100
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(fill)
                        // A sliver stays at one percent, so an almost empty battery is still a battery.
                        .frame(width: max(2.5, width * share), height: geometry.size.height - 2 * Self.inset)
                        .offset(x: Self.inset, y: Self.inset)
                }
            }
            .frame(width: 31, height: 15)
            Capsule()
                .fill(Color.secondary)
                .frame(width: 2.5, height: 6)
        }
        .accessibilityHidden(true)
    }
}

/// "Insulin i kroppen" and "Insulin tilbage": the pump's own two figures, each with the age of the
/// record it came from, under the glucose value. A figure the pump has not renewed for a while is
/// grey, and active insulin older than six hours is not shown as a number at all, because it says
/// nothing about now. nænsom shows what the pump reported and never works out a figure of its own.
struct PumpStatusSection: View {
    @EnvironmentObject private var follow: FollowModel

    var body: some View {
        if let status = follow.pumpStatus, status.iob != nil || status.reservoir != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(status, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(_ status: PumpStatus, now: Date) -> some View {
        let reservoir = status.reservoirAge(now: now) == .withheld ? nil : status.reservoir
        if status.iob != nil || reservoir != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    if let iob = status.iob, let age = status.iobAge(now: now) {
                        tile(
                            title: L("pump.iob"),
                            number: age == .withheld ? nil : PumpStatus.formatIOB(iob.value, locale: AppLanguage.locale),
                            at: iob.at, fresh: age == .fresh, now: now
                        )
                    }
                    if let reservoir, let age = status.reservoirAge(now: now) {
                        tile(
                            title: L("pump.reservoir"),
                            number: PumpStatus.formatReservoir(reservoir.value),
                            at: reservoir.at, fresh: age == .fresh, now: now
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Text(L("pump.fromPump"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One figure: what it is, the number with its unit, and how old it is. Without a number (too
    /// old to show) a dash and when the pump last gave one.
    private func tile(title: String, number: String?, at: Date, fresh: Bool, now: Date) -> some View {
        let age = Glucose.ageText(at: at, now: now, language: AppLanguage.current)
        let spoken = number.map { "\(title): \(L("pump.units.spoken", $0)), \(age)" } ?? "\(title): \(L("pump.last", age))"
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number ?? "–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fresh && number != nil ? Color.primary : Color.secondary)
                if number != nil {
                    Text(PumpStatus.unitLabel(AppLanguage.current))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Text(number == nil ? L("pump.last", age) : age)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
