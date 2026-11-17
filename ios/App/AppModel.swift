import Combine
import FollowCore
import Foundation

/// Ties the pieces together: what the app follows (`FollowModel`), the Live Activity
/// (`LiveActivityController`), the relay registration (`RelaySync`), the reminders
/// (`NotificationController`) and the change reminders (`ChangeReminderController`). The screens
/// call these actions; the pieces never call each other.
@MainActor
final class AppModel: ObservableObject {
    /// One for the process: the window's and the one the app delegate wakes without a window.
    static let shared = AppModel()

    let follow = FollowModel()
    let live = LiveActivityController()
    let relay = RelaySync()
    let notifications = NotificationController.shared
    let changeReminders = ChangeReminderController.shared

    /// A follow link that arrived while the phone is not set up; onboarding picks it up.
    @Published var pendingLink: FollowLink?
    /// A follow link for another site that arrived while the phone follows one; the screen asks first.
    @Published var replacementLink: FollowLink?
    /// True from onboarding until the first activity has been started, so the main screen does not
    /// say "stopped" while it is starting.
    @Published private(set) var startingActivity = false

    private var woken = false
    private var launched = false
    private var syncTask: Task<Void, Never>?
    private var autoStartTask: Task<Void, Never>?

    /// Once, as soon as the process starts, window or not (the app delegate calls it): iOS also
    /// launches the app in the background, when the relay starts a new activity by push-to-start.
    /// The new activity's push token then reaches the relay, and the activity it replaces is taken
    /// off the lock screen, without anyone opening the app. Starts nothing and reads no glucose;
    /// with the change reminders on it reads the pump's changes, so a reminder for a part that
    /// was changed meanwhile is taken back.
    func wake() {
        guard !woken else { return }
        woken = true
        live.onTokensChanged = { [weak self] in
            self?.scheduleSync()
            // A new activity is also the moment iOS runs the app with nobody looking.
            self?.refreshChangesForReminders()
        }
        follow.onPumpChanges = { [weak self] in self?.syncChangeReminders() }
        notifications.onDeviceToken = { [weak self] in self?.scheduleSync() }
        follow.onNewReading = { [weak self] current, previous in
            self?.newReading(current, previous)
        }
        follow.onThresholdsChanged = { [weak self] in
            self?.live.redraw()
            WidgetSync.reload()
            self?.scheduleSync()
        }
        live.observe()
        // The device token is asked for again on every start of the process; it can change.
        if follow.settings.alertsOn || follow.settings.changeRemindersOn {
            Task { await notifications.registerIfAllowed(remote: follow.settings.alertsOn) }
        }
        refreshChangesForReminders()
    }

    /// Once, when the first window appears.
    func launch() {
        guard !launched else { return }
        launched = true
        wake()
        // A removal the relay has not confirmed yet is tried again, followed site or not.
        PendingUnregisterSync.shared.retryIfDue()
        // An address and token saved before the widgets existed move to the shared access group.
        KeychainStore.shareWithExtension()
        syncNow(force: true)
        if follow.source != nil {
            Task {
                await follow.refresh()
                await autoStartIfWanted()
            }
        }
    }

    /// The app came to the foreground: read now, start or reuse the Live Activity, and tell the
    /// relay the phone is still here.
    func becameActive() {
        PendingUnregisterSync.shared.retryIfDue()
        guard follow.source != nil else { return }
        Task {
            await follow.refresh()
            await autoStartIfWanted()
        }
        syncNow(force: false)
    }

    /// With the Live Activity on, at launch and on every return to the foreground: reuse a running
    /// activity (the newest; every other one the phone shows ends) or start one. A new activity's
    /// push token reaches the relay through `onTokensChanged`. A cold launch asks twice at once
    /// (the launch and the first foreground); the second waits for the first, so one decision is
    /// taken and at most one activity started.
    func autoStartIfWanted() async {
        if let underway = autoStartTask {
            await underway.value
            return
        }
        let task = Task { await decideAutoStart() }
        autoStartTask = task
        await task.value
        autoStartTask = nil
    }

    private func decideAutoStart() async {
        guard follow.source != nil else { return }
        let decision = LiveActivitySync.autoStart(
            liveActivityOn: follow.settings.liveActivityOn,
            systemAllows: live.systemAllows,
            running: live.shown(),
            haveReading: follow.latest != nil
        )
        switch decision {
        case .start:
            await startActivity()
        case .reuse(let keep, let others):
            await live.keep(keep, ending: others)
        case .nothing:
            break
        }
    }

    // MARK: - Onboarding and links

    func open(_ url: URL) {
        guard let link = FollowLink.parse(url) else { return }
        guard let source = follow.source else {
            pendingLink = link
            return
        }
        if source == .nightscout(site: link.site, token: link.token) { return }
        replacementLink = link
    }

    /// Onboarding is done: follow the source, read the history, start the Live Activity (on by
    /// default) and register with the relay.
    func finishOnboarding(_ source: FollowSource) {
        pendingLink = nil
        follow.follow(source)
        startingActivity = follow.settings.liveActivityOn
        Task {
            await follow.refresh()
            if follow.settings.liveActivityOn { await startActivity() }
            startingActivity = false
            syncNow(force: true)
        }
    }

    /// Follow a link for another site: remove this phone's registration, then onboard with the link.
    func replace(with link: FollowLink) async {
        replacementLink = nil
        _ = await remove(localOnly: false, fallBackToLocal: true)
        pendingLink = link
    }

    // MARK: - Live Activity

    func startActivity() async {
        guard let latest = follow.latest else { return }
        await live.start(current: latest, previous: follow.previous, unit: follow.settings.unit) { [weak self] in
            guard let self else { return false }
            return self.follow.source != nil && self.follow.settings.liveActivityOn
        }
    }

    func setLiveActivity(_ on: Bool) {
        follow.update { $0.liveActivityOn = on }
        Task {
            if on {
                await startActivity()
            } else {
                await live.endAll()
            }
            scheduleSync()
        }
    }

    /// A newer reading: to the Live Activity and to the widgets, so neither shows less than the app.
    private func newReading(_ current: Reading, _ previous: Reading?) {
        live.show(current: current, previous: previous)
        if let source = follow.source {
            WidgetSync.publish(current: current, previous: previous, source: source)
        }
    }

    // MARK: - Settings

    func setUnit(_ unit: GlucoseUnit) {
        guard unit != follow.settings.unit else { return }
        follow.update { $0.unit = unit }
        WidgetSync.reload()
        // An activity's unit is fixed when it starts: start it again in the new unit.
        if live.isRunning, live.runningUnit != unit {
            Task { await startActivity() }
        }
        scheduleSync()
    }

    func setChangeDays(_ days: Int, for part: PumpPart) {
        follow.update { $0.setDays(days, for: part) }
        syncChangeReminders()
    }

    func setCurveWindow(_ window: CurveWindow) {
        follow.update { $0.curveWindow = window }
    }

    func step(_ kind: GlucoseThresholds.Kind, by steps: Int) {
        follow.step(kind, by: steps)
        live.redraw()
        WidgetSync.reload()
        scheduleSync()
    }

    func resetThresholds() {
        follow.resetThresholds()
        live.redraw()
        WidgetSync.reload()
        scheduleSync()
    }

    /// Reminders on asks for notification permission first; without it the switch stays off.
    func setAlerts(_ on: Bool) {
        guard on else {
            follow.update { $0.alertsOn = false }
            scheduleSync()
            return
        }
        Task {
            let allowed = await notifications.requestPermission()
            follow.update { $0.alertsOn = allowed }
            scheduleSync()
        }
    }

    // MARK: - Change reminders

    /// Change reminders on asks for notification permission first; without it the switch stays off.
    func setChangeReminders(_ on: Bool) {
        guard on else {
            follow.update { $0.changeRemindersOn = false }
            syncChangeReminders()
            return
        }
        Task {
            let allowed = await notifications.requestPermission(remote: false)
            follow.update { $0.changeRemindersOn = allowed }
            syncChangeReminders()
        }
    }

    /// "Remind me again" in the app, for a part that is due.
    func snoozeChange(_ part: PumpPart, for choice: ChangeSnoozeChoice) {
        guard let lastAt = follow.pumpChanges?[part] else { return }
        changeReminders.snooze(part, lastAt: lastAt, for: choice)
    }

    /// A tapped action on a notification, with the app in the background: the snooze is kept and
    /// its reminder scheduled at once, then the pump's changes are read, so a part that was
    /// changed meanwhile is not reminded about again. The snooze is held against the changes the
    /// app has either way: a read that was skipped (one was just made) may already have brought a
    /// newer change than the one the notification was about, and that one's due time then stands.
    func changeReminderAction(_ action: String, part: String?, lastAt: Double?) async {
        guard follow.settings.changeRemindersOn, follow.source != nil else { return }
        guard changeReminders.handle(action: action, part: part, lastAt: lastAt) else { return }
        await follow.refreshPumpChanges()
        syncChangeReminders()
    }

    /// The demo's changes are made up from the time of each read, so there is nothing to remind
    /// about: its reminders are none.
    private func syncChangeReminders() {
        let changes = follow.source?.isDemo == true ? PumpChanges() : follow.pumpChanges
        changeReminders.sync(changes: changes, settings: follow.settings)
    }

    private func refreshChangesForReminders() {
        guard follow.settings.changeRemindersOn, follow.source != nil else { return }
        Task { await follow.refreshPumpChanges() }
    }

    // MARK: - Remove this phone

    /// Ends the activities, deletes the relay's copy and clears the phone, back to onboarding.
    /// Answers false, and changes nothing, when the relay cannot be reached and `localOnly` and
    /// `fallBackToLocal` are false; the screen then offers to remove it from this phone only. A
    /// removal from the phone only leaves the relay's deletion pending (`PendingUnregisterSync`).
    @discardableResult
    func remove(localOnly: Bool, fallBackToLocal: Bool = false) async -> Bool {
        syncTask?.cancel()
        if localOnly {
            await relay.forget()
        } else {
            do {
                try await relay.remove()
            } catch {
                guard fallBackToLocal else { return false }
                await relay.forget()
            }
        }
        await live.endAll()
        notifications.reset()
        changeReminders.clear()
        follow.forget()
        return true
    }

    // MARK: - Relay

    /// Settings and tokens often change several at a time (two tokens, a stepper held down):
    /// wait a moment and send one registration.
    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            syncNow(force: true)
        }
    }

    private func syncNow(force: Bool) {
        guard let source = follow.source else { return }
        let tokens = LivePushTokens(
            pushToStart: live.pushToStartToken,
            activity: live.activityToken,
            activityStartedAt: live.activityStartedAt,
            device: notifications.deviceToken
        )
        var registration = RelayRegistration.make(
            source: source,
            settings: follow.settings,
            thresholds: follow.thresholds,
            tokens: tokens,
            language: AppLanguage.current,
            environment: RelaySync.environment
        )
        // Woken without a window, the tokens come back one at a time (and the device token not at
        // all when notifications were turned off in iOS): what is not here yet is left out, so the
        // relay keeps it, and a wake never takes a token from the relay.
        registration.keepsUnknownTokens = !launched
        relay.sync(registration, force: force)
    }
}
