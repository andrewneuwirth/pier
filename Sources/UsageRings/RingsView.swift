import SwiftUI

/// Ring geometry, shared so the detail card can centre itself over a ring
/// without re-deriving the layout.
let ringDiameter: CGFloat = 56
let ringGap: CGFloat = 2
let ringPadding: CGFloat = 4

struct RingsView: View {
    @ObservedObject var store: Store
    /// Dragging anywhere on the glass moves the panel, so the rings can be
    /// parked wherever the desktop happens to be empty.
    var onDrag: (CGSize) -> Void
    var onDragEnded: () -> Void
    /// Double-click raises the detail card above that ring.
    var onInspect: (Service) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: ringGap) {
                ForEach(Service.allCases) { service in
                    Ring(service: service,
                         usage: store.readings[service] ?? .empty,
                         isRefreshing: store.isRefreshing)
                        .onTapGesture { onInspect(service) }
                }
            }
        }
        .padding(ringPadding)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnded() }
        )
    }
}

private struct Ring: View {
    let service: Service
    let usage: Usage
    let isRefreshing: Bool

    private var headline: Window? { usage.primary }

    var body: some View {
        ZStack {
            // Outer arc: the window that bites first, and the one the centre
            // number reports, so the two never say different things. Inner arc:
            // the longer window, thinner and inset so it reads as secondary.
            Arc(percent: usage.primary?.percent ?? 0, width: 4, inset: 3, tint: service.tint)
            if let secondary = usage.secondary {
                Arc(percent: secondary.percent, width: 2.5, inset: 10, tint: service.tint)
            }
            label
        }
        .frame(width: ringDiameter, height: ringDiameter)
        // Stroked arcs only hit-test on the stroke and the label only on its
        // own bounds, which left the middle of the ring as the sole reliable
        // target. The whole square is the button.
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: .circle)
        .opacity(usage.failed ? 0.55 : usage.stale ? 0.8 : 1)
        .animation(.smooth(duration: 0.45), value: usage)
        .overlay(alignment: .top) {
            if isRefreshing {
                Circle().fill(service.tint).frame(width: 3, height: 3).offset(y: 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
        .help(detail)
    }

    private var label: some View {
        VStack(spacing: 0) {
            Group {
                if let headline {
                    // The sign rides smaller and on the number's baseline, so a
                    // three-digit reading still clears the inner arc.
                    HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                        Text("\(Int(headline.percent.rounded()))")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .opacity(0.7)
                    }
                    .foregroundStyle(severityTint(headline.percent, base: .primary))
                } else {
                    Text(usage.failed ? "!" : "–")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Text(service.title)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The hover tooltip carries everything the circle has no room for.
    private var detail: String {
        if let note = usage.note, usage.failed { return "\(service.title) · \(note)" }
        var lines = [service.title]
        if let note = usage.note { lines[0] += " · \(note)" }
        func describe(_ name: String, _ window: Window?) {
            guard let window else { return }
            let reset = window.resetLabel.map { ", resets in \($0)" } ?? ""
            lines.append("\(name): \(Int(window.percent.rounded()))% used\(reset)")
        }
        describe("Session", usage.short)
        describe("Week", usage.long)
        if lines.count == 1 { lines.append("No usage reported yet") }
        if usage.stale { lines.append("⚠ \(usage.holdReason ?? "refresh failed") — showing last reading") }
        lines.append("Click for detail")
        return lines.joined(separator: "\n")
    }
}

private struct Arc: View {
    let percent: Double
    let width: CGFloat
    let inset: CGFloat
    let tint: Color

    var body: some View {
        let fraction = min(max(percent / 100, 0), 1)
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.14), lineWidth: width)
            Circle()
                .inset(by: width / 2)
                .trim(from: 0, to: fraction)
                .stroke(severityTint(percent, base: tint),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }
}
