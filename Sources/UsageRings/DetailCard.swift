import SwiftUI

let detailCardWidth: CGFloat = 194

/// The card a double-click raises above a ring: both windows spelled out, with
/// the reset times the circle has no room to say.
struct DetailCard: View {
    let service: Service
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if usage.failed {
                Text(usage.note ?? "Usage unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                row("5 hours", usage.short)
                row("7 days", usage.long)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Height comes from the content: an error, or a plan missing a
        // window, makes a shorter card rather than a clipped one.
        .frame(width: detailCardWidth, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle().fill(service.tint).frame(width: 6, height: 6)
            Text(service.title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            if let note = usage.note, !usage.failed {
                Text(note).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    /// A window the plan does not expose is said out loud rather than drawn as
    /// an empty bar, which would read as "none used".
    @ViewBuilder
    private func row(_ name: String, _ window: Window?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let window {
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(severityTint(window.percent, base: .primary))
                } else {
                    Text("not on this plan")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            if let window {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule()
                            .fill(severityTint(window.percent, base: service.tint))
                            .frame(width: max(3, proxy.size.width * min(window.percent / 100, 1)))
                    }
                }
                .frame(height: 4)
                Text(resetText(window.resetsAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 9))
            .foregroundStyle(usage.stale ? severityTint(50, base: .secondary) : Color.secondary.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Says plainly when a number is being held over, so a reading that has
    /// stopped updating never passes for a live one.
    private var footerText: String {
        guard let fetchedAt = usage.fetchedAt else { return "Loading…" }
        let when = "Updated \(ago(fetchedAt))"
        guard usage.stale else { return when }
        return "\(when) · \(usage.holdReason ?? "refresh failed"), retrying"
    }

    /// Reset times are worth stating absolutely — "3:30 PM" tells you whether
    /// it lands before the thing you are about to do; "in 2h" makes you count.
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "No reset reported" }
        guard date.timeIntervalSinceNow > 0 else { return "Resetting now" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Resets \(time)" }
        if calendar.isDateInTomorrow(date) { return "Resets tomorrow, \(time)" }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}


/// Keeps the raised card live: a refresh landing while it is open redraws it
/// in place instead of leaving a stale reading on screen.
struct DetailHost: View {
    @ObservedObject var store: Store
    let service: Service

    var body: some View {
        DetailCard(service: service, usage: store.readings[service] ?? .empty)
    }
}
