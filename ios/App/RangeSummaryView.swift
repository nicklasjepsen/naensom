import FollowCore
import SwiftUI

/// Time in target for the hours the curve shows, opened by a tap on the value: the share of the
/// time in the target range as the large figure, a bar from low to high in the reading colours,
/// the time above and below, the average, and the lowest and highest reading with their times.
/// It follows the curve's 3/6/12/24-hour choice. Colour is never the only signal: every share is
/// also a figure in words. When the readings leave part of the hours out, it says how much time it
/// builds on. What happened, never what to do.
struct RangeSummaryCard: View {
    @EnvironmentObject private var follow: FollowModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let window = follow.settings.curveWindow
            let summary = RangeSummary(follow.readings, window: window, thresholds: follow.thresholds, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                Text(L("range.title", window.hours))
                    .font(.headline)
                if summary.isEmpty {
                    Text(L("main.curve.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    content(summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .environment(\.locale, AppLanguage.locale)
    }

    @ViewBuilder
    private func content(_ summary: RangeSummary) -> some View {
        let percentages = summary.percentages
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("range.percent", percentages[.inTarget] ?? 0))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(L("range.inTarget"))
                .font(.title3)
            Spacer(minLength: 12)
            Text(duration(summary.seconds(.inTarget)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        BandBar(summary: summary)
            .frame(height: 12)
            .accessibilityHidden(true)
        VStack(spacing: 6) {
            share(L("range.above"), percent: percentages[.above] ?? 0, seconds: summary.seconds(.above))
            share(L("range.below"), percent: percentages[.below] ?? 0, seconds: summary.seconds(.below))
        }
        Divider()
        VStack(spacing: 6) {
            if let average = summary.averageMgdl {
                figure(L("range.average"), mgdl: average, at: nil)
            }
            if let highest = summary.highest {
                figure(L("range.highest"), mgdl: highest.mgdl, at: highest.at)
            }
            if let lowest = summary.lowest {
                figure(L("range.lowest"), mgdl: lowest.mgdl, at: lowest.at)
            }
        }
        if !summary.isComplete {
            Text(L("range.partial", duration(summary.covered)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// "Over målet   21 %   1 t 15 min"; the time is left out when there was none.
    private func share(_ name: String, percent: Int, seconds: TimeInterval) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer(minLength: 12)
            if seconds > 0 {
                Text(duration(seconds)).foregroundStyle(.secondary)
            }
            Text(L("range.percent", percent))
                .fontWeight(.semibold)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .font(.subheadline)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    /// "Højest   14,2 mmol/L   19.40": a reading with the time it was read; the average has none,
    /// it belongs to the hours in the heading.
    private func figure(_ name: String, mgdl: Int, at: Date?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer(minLength: 12)
            if let at {
                Text(at, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
            }
            Text("\(Glucose.format(mgdl, unit: follow.settings.unit, locale: AppLanguage.locale)) \(follow.settings.unit.label)")
                .fontWeight(.semibold)
                .foregroundStyle(Glucose.color(mgdl, thresholds: follow.thresholds, isStale: false).color)
        }
        .font(.subheadline)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        RangeSummary.durationText(seconds, language: AppLanguage.current)
    }
}

/// The hours as one bar, low to the left and high to the right, each band as wide as its share of
/// the time and in the colour its readings have on the curve.
private struct BandBar: View {
    let summary: RangeSummary
    private static let bands: [GlucoseBand] = [.urgentLow, .low, .inRange, .high, .urgentHigh]
    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let present = Self.bands.filter { summary.fraction($0) > 0 }
            let width = max(0, geometry.size.width - Self.gap * CGFloat(max(present.count - 1, 0)))
            HStack(spacing: Self.gap) {
                ForEach(present, id: \.self) { band in
                    Rectangle()
                        .fill(Self.colour(band))
                        .frame(width: width * summary.fraction(band))
                }
            }
            .clipShape(Capsule())
        }
    }

    private static func colour(_ band: GlucoseBand) -> Color {
        switch band {
        case .urgentLow, .urgentHigh: return GlucoseColor.red.color
        case .low, .high: return GlucoseColor.yellow.color
        case .inRange: return GlucoseColor.green.color
        }
    }
}
