import Foundation
import os

/// "At 20:00, switch to Night."
struct ScheduleRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var profileID: UUID
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        profileID: UUID,
        hour: Int,
        minute: Int = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.profileID = profileID
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
    }

    var timeLabel: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var minuteOfDay: Int { hour * 60 + minute }
}

/// Fires schedule rules as their times come round.
///
/// Ticks once a minute rather than scheduling a timer per rule: rules can be
/// edited at any moment, the machine sleeps through its own timers, and a
/// once-a-minute wake-up is cheap enough not to matter.
@MainActor
final class ScheduleEngine {
    /// Called with the rule that should be applied now.
    var onFire: ((ScheduleRule) -> Void)?

    private var rules: [ScheduleRule] = []
    private var timer: Timer?
    private var lastFiredMinute: Int?
    private let logger = Logger(subsystem: "com.github.ozers.Sideband", category: "schedule")

    func update(rules: [ScheduleRule], isEnabled: Bool) {
        self.rules = rules.filter(\.isEnabled)

        timer?.invalidate()
        timer = nil
        guard isEnabled, !self.rules.isEmpty else { return }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common mode, so the timer keeps running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Applies the rule in effect right now, if any.
    ///
    /// Used at launch and after a display reconnects, where the last transition
    /// may have happened while the app was not running or the monitor was
    /// asleep. Without this, plugging in at 22:00 leaves the panel on whatever
    /// the day profile set.
    func applyCurrentRule() {
        guard let rule = ruleInEffect() else { return }
        onFire?(rule)
        lastFiredMinute = currentMinuteOfDay()
    }

    private func tick() {
        let now = currentMinuteOfDay()
        guard now != lastFiredMinute else { return }
        lastFiredMinute = now

        guard let rule = rules.first(where: { $0.minuteOfDay == now }) else { return }
        logger.debug("firing schedule rule at \(rule.timeLabel)")
        onFire?(rule)
    }

    /// The most recent rule at or before now, wrapping to yesterday's last rule
    /// when the day's first rule has not been reached yet.
    private func ruleInEffect() -> ScheduleRule? {
        guard !rules.isEmpty else { return nil }
        let now = currentMinuteOfDay()
        let sorted = rules.sorted { $0.minuteOfDay < $1.minuteOfDay }
        return sorted.last { $0.minuteOfDay <= now } ?? sorted.last
    }

    private func currentMinuteOfDay() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
