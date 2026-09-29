import SwiftUI
import WidgetKit

// The Usage Rings as a real desktop / Notification Center widget. Readings
// come from the Usage Rings app (see SharedUsage.swift); the widget only draws.

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
    var problem: String? = nil
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SharedSnapshot(
            claude: SharedReading(short: SharedWindow(percent: 34, resetsAt: Date().addingTimeInterval(7200)),
                                  long: SharedWindow(percent: 12, resetsAt: Date().addingTimeInterval(4 * 86400))),
            chatgpt: SharedReading(long: SharedWindow(percent: 8, resetsAt: Date().addingTimeInterval(5 * 86400))),
            updated: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : UsageEntry(date: Date(), snapshot: SharedStore.read()))
    }

    /// The same reading, redrawn every 15 minutes so "resets in 3h" keeps
    /// counting down between the app's refreshes (which reload it directly).
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snap = SharedStore.read()
        let problem = snap == nil ? SharedStore.diagnose() : nil
        let now = Date()
        let entries = (0..<8).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 900), snapshot: snap, problem: problem) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(2 * 3600))))
    }
}

private let claudeTint = Color(red: 0.85, green: 0.47, blue: 0.34)
private let chatgptTint = Color(red: 0.06, green: 0.64, blue: 0.50)

private func severity(_ percent: Double, base: Color) -> Color {
    if percent >= 80 { return Color(red: 0.91, green: 0.34, blue: 0.33) }
    if percent >= 50 { return Color(red: 0.95, green: 0.71, blue: 0.27) }
    return base
}

private func resetText(_ w: SharedWindow?, now: Date) -> String? {
    guard let d = w?.resetsAt, d > now else { return nil }
    let m = Int(d.timeIntervalSince(now) / 60)
    if m < 60 { return "\(m)m" }
    if m < 24 * 60 { return "\(Int((Double(m) / 60).rounded()))h" }
    return d.formatted(.dateTime.weekday(.abbreviated).hour())
}

private struct WidgetRing: View {
    let name: String
    let reading: SharedReading?
    let tint: Color
    let size: CGFloat
    let now: Date

    var body: some View {
        let primary = reading?.short ?? reading?.long
        let secondary = reading?.short == nil ? nil : reading?.long
        let thick = size * 0.1, thin = size * 0.045
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: thick)
            if let p = primary {
                Circle().trim(from: 0, to: min(1, max(0.005, p.percent / 100)))
                    .stroke(severity(p.percent, base: tint), style: StrokeStyle(lineWidth: thick, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            if let s = secondary {
                Circle().stroke(.primary.opacity(0.08), lineWidth: thin).padding(thick * 1.6)
                Circle().trim(from: 0, to: min(1, max(0.005, s.percent / 100)))
                    .stroke(severity(s.percent, base: tint).opacity(0.85), style: StrokeStyle(lineWidth: thin, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(thick * 1.6)
            }
            VStack(spacing: 0) {
                if let p = primary {
                    Text("\(Int(p.percent.rounded()))%").font(.system(size: size * 0.24, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                } else {
                    Text(reading?.failed == true ? "!" : "–").font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(name).font(.system(size: size * 0.11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// "5h · 2h" (short window resets in) or "Week · Sun 11 AM".
private func resetLine(_ r: SharedReading?, now: Date) -> String {
    guard let r else { return "Open Usage Rings" }
    if r.failed { return r.note ?? "Unavailable" }
    if r.short != nil { return "resets \(resetText(r.short, now: now) ?? "soon")" }
    if r.long != nil { return "week · \(resetText(r.long, now: now) ?? "soon")" }
    return "—"
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry

    var body: some View {
        let s = entry.snapshot
        if s == nil, let problem = entry.problem {
            Text(problem).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        } else {
            switch family {
            case .systemMedium:
                HStack(spacing: 14) {
                    row("Claude", s?.claude, claudeTint, ring: 82, text: 12)
                    row("ChatGPT", s?.chatgpt, chatgptTint, ring: 82, text: 12)
                }
            case .systemLarge:
                // Stacked: Claude over ChatGPT.
                VStack(alignment: .leading, spacing: 18) {
                    row("Claude", s?.claude, claudeTint, ring: 128, text: 17)
                    Divider().opacity(0.4)
                    row("ChatGPT", s?.chatgpt, chatgptTint, ring: 128, text: 17)
                }
                .padding(.horizontal, 4)
            default:
                // Stacked: Claude over ChatGPT.
                VStack(alignment: .leading, spacing: 8) {
                    row("Claude", s?.claude, claudeTint, ring: 58, text: 10.5)
                    row("ChatGPT", s?.chatgpt, chatgptTint, ring: 58, text: 10.5)
                }
            }
        }
    }

    /// A ring with its numbers beside it: each window on one line, its reset
    /// under it. Lines shrink rather than truncate or wrap.
    private func row(_ name: String, _ r: SharedReading?, _ tint: Color, ring: CGFloat, text: CGFloat) -> some View {
        HStack(spacing: ring * 0.16) {
            WidgetRing(name: name, reading: r, tint: tint, size: ring, now: entry.date)
            VStack(alignment: .leading, spacing: text * 0.45) {
                if let r, !r.failed {
                    if let w = r.short { line("5-hour", w, text) }
                    if let w = r.long { line("Week", w, text) }
                    if r.stale { Text("last reading").font(.system(size: text * 0.8)).foregroundStyle(.orange) }
                } else {
                    Text(r?.note ?? "Open Usage Rings").font(.system(size: text)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ label: String, _ w: SharedWindow, _ size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text("\(Int(w.percent.rounded()))%").fontWeight(.bold)
            }
            .font(.system(size: size, weight: .semibold))
            if let reset = resetText(w, now: entry.date) {
                Text("resets \(reset)").font(.system(size: size * 0.82)).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageRingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageRings", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage Rings")
        .description("How much of your Claude and ChatGPT allowance is used, and when it resets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct UsageRingsWidgets: WidgetBundle {
    var body: some Widget { UsageRingsWidget() }
}
