import AppKit
import SwiftUI
import MacToolsKit

final class TrayModel: ObservableObject {
    @Published var items: [BarItem] = []
    @Published var trusted = true
    @Published var loading = true
    var onSelect: (BarItem) -> Void = { _ in }
    var onGrant: () -> Void = {}
}

struct TrayView: View {
    @ObservedObject var model: TrayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.trusted {
                permission
            } else if model.items.isEmpty {
                Text(model.loading ? "Looking…" : "Nothing in the menu bar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(MT.Space.s12)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.items) { item in
                            Row(item: item) { model.onSelect(item) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MT.Space.s6)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: MT.Space.s8) {
            Text("Pier needs Accessibility access to see and open menu bar icons.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { model.onGrant() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(MT.Space.s10)
    }
}

private struct Row: View {
    let item: BarItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MT.Space.s10) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, height: 18)
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                }
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !item.hidden {
                    Circle().fill(Color.mtInkMuted.opacity(0.5)).frame(width: 4, height: 4)
                        .help("Visible in the menu bar")
                }
            }
            .padding(.horizontal, MT.Space.s10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(hover ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
            .animation(MT.Motion.allowed(MT.Motion.quick), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Borderless glass panel that can take Esc without activating Pier.
final class TrayPanel: NSPanel {
    var onEscape: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape() }
}
