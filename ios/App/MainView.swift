import Charts
import FollowCore
import SwiftUI

/// The main screen (plan §1, §3): the value in its colour with arrow, change and age; the curve;
/// the Live Activity's state. Every value is shown with its age, and colour is never the only
/// signal: a stale reading also says so in words.
struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var follow: FollowModel
    @EnvironmentObject private var live: LiveActivityController
    @State private var showSettings = false
    /// True while a finger is moving along the curve, so the page stays put under it.
    @State private var scrubbing = false
    /// Time in target under the value, opened and closed by a tap on the value; kept between launches.
    @AppStorage("main.showRangeSummary") private var showRangeSummary = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // The name as the brand writes it, lower case and larger than a navigation
                    // title, in the value's rounded face.
                    HStack(alignment: .center) {
                        Text(verbatim: "nænsom")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 12)
                        PumpBatteryBadge()
                    }
                    ReadingHeader(showRangeSummary: $showRangeSummary)
                    if showRangeSummary, follow.latest != nil {
                        RangeSummaryCard()
                    }
                    LiveActivityBanner()
                    PumpStatusSection()
                    CurveSection(scrubbing: $scrubbing)
                    PumpChangesSection()
                    if follow.source?.isDemo == true {
                        Label(L("main.demo"), systemImage: "theatermasks")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(L("disclaimer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                // Room to scroll the last lines clear of the settings button.
                .padding(.bottom, SettingsButton.size + 12)
            }
            .scrollDisabled(scrubbing)
            // No navigation bar: it held only the settings button and pushed everything down.
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                SettingsButton { showSettings = true }
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
            .refreshable { await follow.refresh() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .task(id: follow.sourceKey) { await follow.refreshWhileVisible() }
    }
}

/// Settings, as a round button floating over the bottom corner of the screen, where a thumb
/// reaches it and it takes no room from the content. Glass where the system has it (iOS 26),
/// otherwise the system's thin material.
private struct SettingsButton: View {
    static let size: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(FloatingSurface())
        .accessibilityLabel(L("settings.title"))
    }
}

private struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

/// The value, arrow, unit, change and age. Re-rendered every 15 seconds so the age and the
/// stale state stay true between readings. A tap on it opens time in target for the hours the
/// curve shows, right under it, and a second tap closes it; the value itself never goes away.
private struct ReadingHeader: View {
    @EnvironmentObject private var follow: FollowModel
    @Binding var showRangeSummary: Bool

    var body: some View {
        if let latest = follow.latest {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                content(latest, now: context.date)
            }
        } else if let error = follow.error {
            Label(error.message(in: AppLanguage.current), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(L("main.loading")).foregroundStyle(.secondary)
            }
        }
    }

    private func content(_ latest: Reading, now: Date) -> some View {
        let unit = follow.settings.unit
        let stale = Glucose.isStale(latest, now: now)
        let colour = Glucose.color(latest, thresholds: follow.thresholds, now: now).color
        let value = Glucose.format(latest.mgdl, unit: unit, locale: AppLanguage.locale)
        let arrow = Glucose.arrow(latest.direction)
        let age = Glucose.ageText(latest, now: now, language: AppLanguage.current)
        let delta = Glucose.formatDelta(latest, previous: follow.previous, unit: unit, locale: AppLanguage.locale)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { showRangeSummary.toggle() }
        } label: {
            header(value: arrow.isEmpty ? value : "\(value) \(arrow)", unit: unit, colour: colour, age: age, delta: delta, stale: stale)
        }
        .buttonStyle(.plain)
        .accessibilityHint(showRangeSummary ? L("range.hide") : L("range.show"))
    }

    private func header(value: String, unit: GlucoseUnit, colour: Color, age: String, delta: String?, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(colour)
                Text(unit.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // The same small arrow as the rows under "Skift": this opens and closes.
                Image(systemName: showRangeSummary ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text(age)
                if let delta {
                    Text("·")
                    Text(delta).monospacedDigit()
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            if stale {
                Label(L("main.stale"), systemImage: "clock.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let error = follow.error {
                Label(error.message(in: AppLanguage.current), systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "Live Activity stopped, tap to restart" (plan §4 fallback) when it should be running and is not:
/// it ended after 8 hours without a push-to-start, or it was swiped away.
private struct LiveActivityBanner: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var follow: FollowModel
    @EnvironmentObject private var live: LiveActivityController

    var body: some View {
        let status = LiveActivitySync.status(wanted: follow.settings.liveActivityOn, running: live.isRunning)
        VStack(alignment: .leading, spacing: 6) {
            if status == .stopped, !app.startingActivity, follow.latest != nil {
                Button {
                    Task { await app.startActivity() }
                } label: {
                    Label(L("main.liveStopped"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if let error = live.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// "Skift": when the reservoir, the site and the sensor are next due, in plain words ("Skiftes om 1 dag").
/// Tapping a part shows when the pump recorded the last change, when the next is due, and how many
/// days it lasts. Shown only once the site has sent a change; past due reads in the plain text
/// colour with a clock symbol, a reminder and not an alarm. With the change reminders on, a part
/// that is due can be put off from here too ("Påmind mig igen"), like on its notification.
private struct PumpChangesSection: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var follow: FollowModel
    @ObservedObject private var reminders = ChangeReminderController.shared
    @State private var open: PumpPart?

    var body: some View {
        if let changes = follow.pumpChanges, !changes.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("changes.title"))
                        .font(.headline)
                        .padding(.bottom, 4)
                    ForEach(PumpPart.allCases, id: \.self) { part in
                        if part != .cartridge { Divider() }
                        row(part, lastAt: changes[part], now: context.date)
                    }
                    Text(L("changes.fromPump"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder
    private func row(_ part: PumpPart, lastAt: Date?, now: Date) -> some View {
        let days = follow.settings.days(for: part)
        let dueAt = PumpCountdown.dueAt(lastAt: lastAt, days: days)
        let countdown = PumpCountdown.to(dueAt, now: now)
        let expanded = open == part
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open = expanded ? nil : part }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.name(part)).fontWeight(.semibold)
                    Spacer(minLength: 12)
                    if countdown.isPastDue {
                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                    }
                    Text(countdown.text(in: AppLanguage.current))
                        .fontWeight(countdown.isPastDue ? .semibold : .regular)
                        .foregroundStyle(countdown.isPastDue ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L("changes.hint"))
            if expanded {
                Group {
                    if let lastAt {
                        Text(L("changes.last", Self.time(lastAt)))
                    } else {
                        Text(L("changes.noneYet"))
                    }
                    if let dueAt {
                        Text(L("changes.next", Self.time(dueAt)))
                    }
                    // A menu picker outside a Form shows only its value, so the label is its own text.
                    HStack(spacing: 6) {
                        Text(L("changes.lasts"))
                        Picker(L("changes.lasts"), selection: Binding(get: { days }, set: { app.setChangeDays($0, for: part) })) {
                            ForEach(Array(PumpCountdown.dayChoices), id: \.self) { n in
                                Text(n == 1 ? L("changes.day", n) : L("changes.days", n)).tag(n)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    if follow.settings.changeRemindersOn, follow.source?.isDemo == false, countdown.isPastDue {
                        if let snooze = reminders.snoozes[part], snooze.holds(for: lastAt, now: now) {
                            Text(L("changes.snoozed", Self.time(snooze.until)))
                        }
                        Menu(L("changes.snooze")) {
                            ForEach(ChangeSnoozeChoice.allCases, id: \.self) { choice in
                                Button(ChangeReminderController.label(choice)) { app.snoozeChange(part, for: choice) }
                            }
                        }
                        .foregroundStyle(.tint)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            }
        }
    }

    private static func name(_ part: PumpPart) -> String {
        switch part {
        case .cartridge: return L("changes.cartridge")
        case .cannula: return L("changes.cannula")
        case .sensor: return L("changes.sensor")
        }
    }

    private static func time(_ date: Date) -> String { ChangeReminderController.time(date) }
}

/// The 3/6/12/24-hour curve with the window picker.
private struct CurveSection: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var follow: FollowModel
    @Binding var scrubbing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("main.window"), selection: Binding(get: { follow.settings.curveWindow }, set: { app.setCurveWindow($0) })) {
                ForEach(CurveWindow.allCases, id: \.self) { window in
                    Text(L("main.window.hours", window.hours)).tag(window)
                }
            }
            .pickerStyle(.segmented)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                CurveChart(
                    points: ReadingHistory.points(follow.readings, window: follow.settings.curveWindow, now: context.date),
                    window: follow.settings.curveWindow,
                    thresholds: follow.thresholds,
                    unit: follow.settings.unit,
                    now: context.date,
                    scrubbing: $scrubbing
                )
            }
        }
    }
}

/// One dot per reading, coloured by its band; the target range as a faint green band and the
/// urgent values as faint dashed lines. The x axis is the time of day.
///
/// A finger anywhere on the curve picks the reading straight above or below it: sliding sideways
/// moves from reading to reading, each with its exact value and time and a light tick from the
/// phone, and the page does not scroll meanwhile. A slide that starts up or down scrolls the page
/// as usual. A tap picks the nearest reading too; tapping it again, or far from any dot, hides it.
private struct CurveChart: View {
    let points: [Reading]
    let window: CurveWindow
    let thresholds: GlucoseThresholds
    let unit: GlucoseUnit
    let now: Date
    @Binding var scrubbing: Bool
    @State private var selectedAt: Date?
    /// Whether the slide under way is along the curve (true) or a scroll of the page (false);
    /// decided by its first movement, nil between slides.
    @State private var slideIsAlongCurve: Bool?
    /// True while a finger is sliding; SwiftUI resets it when the slide ends or is cancelled.
    @GestureState private var sliding = false

    /// The selected reading, while it is still on the curve.
    private var selected: Reading? {
        guard let selectedAt else { return nil }
        return points.first { $0.at == selectedAt }
    }

    var body: some View {
        let start = now.addingTimeInterval(-window.duration)
        let domain = ReadingHistory.yDomainMgdl(points, thresholds: thresholds)
        let low = Double(domain.lowerBound)
        let high = Double(domain.upperBound)
        Chart {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", now),
                yStart: .value("Low", shown(Double(thresholds.lowMgdl))),
                yEnd: .value("High", shown(Double(thresholds.highMgdl)))
            )
            .foregroundStyle(Color.green.opacity(0.1))
            ForEach([thresholds.urgentLowMgdl, thresholds.urgentHighMgdl].filter { Double($0) > low && Double($0) < high }, id: \.self) { urgent in
                RuleMark(y: .value("Urgent", shown(Double(urgent))))
                    .foregroundStyle(Color.red.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(points, id: \.at) { reading in
                PointMark(
                    x: .value("Time", reading.at),
                    y: .value("Glucose", shown(Double(reading.mgdl)))
                )
                .symbolSize(22)
                .foregroundStyle(Glucose.color(reading.mgdl, thresholds: thresholds, isStale: false).color)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.at))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        SelectedReadingLabel(reading: selected, unit: unit, thresholds: thresholds)
                    }
                PointMark(
                    x: .value("Time", selected.at),
                    y: .value("Glucose", shown(Double(selected.mgdl)))
                )
                .symbolSize(90)
                .foregroundStyle(Glucose.color(selected.mgdl, thresholds: thresholds, isStale: false).color)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { tap in
                            select(at: tap.location, proxy: proxy, geometry: geometry)
                        }
                    )
                    // Beside the page's own scrolling, not in place of it: a slide that starts
                    // up or down is left to the page.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .updating($sliding) { _, state, _ in state = true }
                            .onChanged { slide in
                                if slideIsAlongCurve == nil {
                                    let along = abs(slide.translation.width) > abs(slide.translation.height)
                                    slideIsAlongCurve = along
                                    if along { scrubbing = true }
                                }
                                if slideIsAlongCurve == true {
                                    scrub(to: slide.location, proxy: proxy, geometry: geometry)
                                }
                            }
                    )
            }
        }
        .onChange(of: sliding) { _, isSliding in
            if !isSliding {
                slideIsAlongCurve = nil
                scrubbing = false
            }
        }
        // One light tick for each reading the finger reaches, none when the selection is cleared.
        .sensoryFeedback(trigger: selectedAt) { _, picked in
            picked == nil ? nil : .selection
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: shown(low)...shown(high))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: window.axisStrideHours)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 240)
        .accessibilityLabel(L("main.curve", window.hours))
        .overlay {
            if points.isEmpty {
                Text(L("main.curve.empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Selects the reading nearest the tap in time, within a quarter of an hour; a second tap on
    /// the same reading, or a tap with no reading near, clears the selection.
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let nearest = reading(under: location, proxy: proxy, geometry: geometry)
        selectedAt = selectedAt == nearest?.at ? nil : nearest?.at
    }

    /// While a finger slides along the curve: the reading in line with it, or none where the curve
    /// has a gap. The height of the finger does not matter.
    private func scrub(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let nearest = reading(under: location, proxy: proxy, geometry: geometry)
        if selectedAt != nearest?.at { selectedAt = nearest?.at }
    }

    /// The reading nearest in time to a point on the chart, within a quarter of an hour of it.
    private func reading(under location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Reading? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let x = location.x - geometry[plotFrame].origin.x
        guard let time: Date = proxy.value(atX: x) else { return nil }
        let nearest = points.min { abs($0.at.timeIntervalSince(time)) < abs($1.at.timeIntervalSince(time)) }
        guard let nearest, abs(nearest.at.timeIntervalSince(time)) <= 15 * 60 else { return nil }
        return nearest
    }

    /// mg/dL in the shown unit, unrounded so the band edges sit exactly.
    private func shown(_ mgdl: Double) -> Double {
        unit == .mmolL ? mgdl / Glucose.mgdlPerMmolL : mgdl
    }
}

/// The exact value of a tapped reading, with the time it was read, since a value is never shown
/// without when it is from.
private struct SelectedReadingLabel: View {
    let reading: Reading
    let unit: GlucoseUnit
    let thresholds: GlucoseThresholds

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Glucose.format(reading.mgdl, unit: unit, locale: AppLanguage.locale))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Glucose.color(reading.mgdl, thresholds: thresholds, isStale: false).color)
                Text(unit.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(reading.at, format: .dateTime.hour().minute())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .environment(\.locale, AppLanguage.locale)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Opaque and in the plain text colour: inside a chart annotation the mark's colour would
        // otherwise tint the background and the secondary text, leaving green on green.
        .foregroundStyle(Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
