import AppKit
import SwiftUI

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
                    .padding(14)
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
        .padding(6)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tuck needs Accessibility access to see and open menu bar icons.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { model.onGrant() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(10)
    }
}

private struct Row: View {
    let item: BarItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
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
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 4, height: 4)
                        .help("Visible in the menu bar")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hover ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Borderless glass panel that can take Esc without activating Tuck.
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
