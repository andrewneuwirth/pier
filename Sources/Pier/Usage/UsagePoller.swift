import AppKit
import SwiftUI
import WidgetKit

/// Holds the two readings and decides when to go get them again.
///
/// Both endpoints are a single small GET that costs no model tokens, so the
/// expense of refreshing is a radio wake, not money. The pacing below is about
/// battery alone: nothing is polled while the display is asleep, Low Power Mode
/// stretches the interval, and waking the display refreshes immediately so what
/// you see the moment you look at it is current.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var readings: [Service: Usage] = [:]
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var awake = true

    /// Each service's own endpoint is rate limited, independently of the plan
    /// limits it reports. Clicking a ring must never be able to trip that, so
    /// every service carries its own earliest-next-call time.
    private var nextAllowed: [Service: Date] = [:]
    private let cooldown: TimeInterval = 60
    private let rateLimitedCooldown: TimeInterval = 5 * 60

    private var interval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 * 60 : 5 * 60
    }

    init() {
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
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
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let now = Date()
        let due = Service.allCases.filter { (nextAllowed[$0] ?? .distantPast) <= now }
        guard !isRefreshing, !due.isEmpty else { return }

        isRefreshing = true
        Task {
            await withTaskGroup(of: (Service, Usage).self) { group in
                for service in due {
                    group.addTask { (service, await Self.load(service)) }
                }
                for await (service, fresh) in group { apply(service, fresh) }
            }
            isRefreshing = false
        }
    }

    private static func load(_ service: Service) async -> Usage {
        switch service {
        case .claude: await ClaudeSource.load()
        case .chatgpt: await ChatGPTSource.load()
        }
    }

    /// A refusal is not news. If there is already a good reading, it is kept and
    /// flagged stale rather than replaced by an error, so a momentary 429 cannot
    /// wipe a number that is still substantially true.
    private func apply(_ service: Service, _ fresh: Usage) {
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
        publishToWidget()
    }

    /// Hands the readings to the widget (it can't fetch them itself), and
    /// reloads it only when something it shows changed: widget reloads are
    /// budgeted by macOS.
    private func publishToWidget() {
        func shared(_ u: Usage?) -> SharedReading? {
            guard let u else { return nil }
            func w(_ x: Window?) -> SharedWindow? { x.map { SharedWindow(percent: $0.percent.rounded(), resetsAt: $0.resetsAt) } }
            return SharedReading(short: w(u.short), long: w(u.long), note: u.note, failed: u.failed, stale: u.stale)
        }
        let snap = SharedSnapshot(claude: shared(readings[.claude]), chatgpt: shared(readings[.chatgpt]), updated: Date())
        if SharedStore.write(snap) { WidgetCenter.shared.reloadAllTimelines() }
    }
}
