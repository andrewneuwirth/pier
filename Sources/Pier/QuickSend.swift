import AppKit

/// Downloads' quick actions. None of them sends anything: each fills in a message or a chat box
/// and brings the app forward, and you press Send yourself.
@MainActor
enum QuickSend {
    enum Target: String, CaseIterable, Identifiable {
        case myself = "Text Myself", claude = "Claude", chatGPT = "ChatGPT"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .myself: "message.fill"; case .claude: "sparkle"; case .chatGPT: "bubble.left.fill" }
        }
        var appPath: String? {
            switch self { case .myself: nil; case .claude: "/Applications/Claude.app"; case .chatGPT: "/Applications/ChatGPT.app" }
        }
    }

    static func send(_ file: URL, to target: Target) {
        switch target {
        case .myself: textMyself(file)
        case .claude, .chatGPT: pasteInto(target.appPath!, file)
        }
    }

    /// A Messages compose window addressed to your own number (groups.json "myNumber") with the
    /// file attached.
    private static func textMyself(_ file: URL) {
        guard let service = NSSharingService(named: .composeMessage) else { return }
        if let number = GroupsFile.load().myNumber, !number.isEmpty { service.recipients = [number] }
        NSApp.activate()   // the compose sheet needs Pier frontmost to appear
        service.perform(withItems: [file])
    }

    /// Opens the app and pastes the file into whatever box has focus (the chat composer), the same as
    /// copying it in Finder and pressing ⌘V. Never presses Return.
    private static func pasteInto(_ appPath: String, _ file: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config) { _, _ in
            // Give the app a moment to come forward and focus its composer before pasting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { pressCommandV() }
        }
    }

    /// Posting keystrokes needs Accessibility, which Pier already asks for.
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)   // 9 = V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
