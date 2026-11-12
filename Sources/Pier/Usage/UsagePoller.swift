import AppKit
import MacToolsKit

/// Fetches the Claude and ChatGPT readings and writes them to UsageSnapshot.file
/// (~/Library/Application Support/UsageRings/usage.json), which DockModel reads.
/// Moved from the Usage Rings app, with the same pacing.
///
/// Both endpoints are a single small GET that costs no model tokens, so the
/// expense of refreshing is a radio wake, not money. The pacing below is about
/// battery alone: nothing is polled while the display is asleep, Low Power Mode
/// stretches the interval, and waking the display refreshes immediately.
@MainActor
final class UsagePoller {
    private var readings: [UsageService: Usage] = [:]
    private var isRefreshing = false
    private var timer: Timer?
    private var awake = true
    /// Called after a write that changed what is stored.
    var onChange: () -> Void = {}

    /// Each service's own endpoint is rate limited, independently of the plan
    /// limits it reports, so every service carries its own earliest-next-call time.
    private var nextAllowed: [UsageService: Date] = [:]
    private let cooldown: TimeInterval = 60
    private let rateLimitedCooldown: TimeInterval = 5 * 60

    private var interval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 * 60 : 5 * 60
    }

    init() {
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        resume()
    }

    /// Asleep displays get no timer at all, rather than a slower one.
    private func suspend() {
        awake = false
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard !awake || timer == nil else { return }
        awake = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let now = Date()
        let due = UsageService.allCases.filter { (nextAllowed[$0] ?? .distantPast) <= now }
        guard !isRefreshing, !due.isEmpty else { return }

        isRefreshing = true
        Task {
            await withTaskGroup(of: (UsageService, Usage).self) { group in
                for service in due {
                    group.addTask { (service, await Self.load(service)) }
                }
                for await (service, fresh) in group { apply(service, fresh) }
            }
            isRefreshing = false
        }
    }

    nonisolated private static func load(_ service: UsageService) async -> Usage {
        switch service {
        case .claude: await ClaudeSource.load()
        case .chatgpt: await ChatGPTSource.load()
        }
    }

    /// A refusal is not news. If there is already a good reading, it is kept and
    /// flagged stale rather than replaced by an error, so a momentary 429 cannot
    /// wipe a number that is still substantially true.
    private func apply(_ service: UsageService, _ fresh: Usage) {
        nextAllowed[service] = Date()
            .addingTimeInterval(fresh.rateLimited ? rateLimitedCooldown : cooldown)

        if fresh.failed, let previous = readings[service], !previous.failed {
            var held = previous
            held.stale = true
            held.holdReason = fresh.note   // carried through, not swallowed
            readings[service] = held
        } else {
            readings[service] = fresh
        }
        publish()
    }

    private func publish() {
        func shared(_ u: Usage?) -> UsageSnapshot.Reading? {
            guard let u else { return nil }
            func w(_ x: UsageWindow?) -> UsageSnapshot.Window? { x.map { .init(percent: $0.percent.rounded(), resetsAt: $0.resetsAt) } }
            return .init(short: w(u.short), long: w(u.long), note: u.note, failed: u.failed, stale: u.stale)
        }
        // A refusal right after launch has no in-memory reading to hold, so fall back to the last good one on disk:
        // a restart during a 429 cooldown must not blank a ring that was showing a real number.
        let disk = UsageSnapshot.read()
        func held(_ new: UsageSnapshot.Reading?, _ old: UsageSnapshot.Reading?) -> UsageSnapshot.Reading? {
            guard let new, new.failed, var old, !old.failed else { return new }
            old.stale = true
            old.note = new.note
            return old
        }
        let snap = UsageSnapshot(claude: held(shared(readings[.claude]), disk?.claude),
                                 chatgpt: held(shared(readings[.chatgpt]), disk?.chatgpt), updated: Date())
        if snap.write() { onChange() }
    }
}
