import SwiftUI
import MacToolsKit

/// One rate-limit window as both services report it: how much of the allowance
/// is spent, and when it comes back.
struct Window: Equatable {
    var percent: Double
    var resetsAt: Date?

    /// "3h" / "42m" / "Sun" — short enough for a 72pt circle's tooltip.
    var resetLabel: String? {
        guard let resetsAt else { return nil }
        let mins = Int(resetsAt.timeIntervalSinceNow / 60)
        guard mins > 0 else { return nil }
        if mins < 60 { return "\(mins)m" }
        if mins < 60 * 24 { return "\(Int(round(Double(mins) / 60)))h" }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// What one service's ring draws. Either window can be absent — plans differ in
/// which ones they expose — and a missing window is left undrawn rather than
/// rendered as a confident zero.
struct Usage: Equatable {
    var short: Window?          // the window you bump into mid-session
    var long: Window?           // the multi-day one
    var note: String?           // plan name, or why there is nothing to show
    var failed = false
    var fetchedAt: Date?        // when this reading actually came off the wire
    var stale = false           // held over because a later refresh was refused
    var holdReason: String?     // and what the refusal said, verbatim
    var rateLimited = false     // the refusal was a 429, so back off harder

    /// The thick outer arc, and the number in the middle. Plans that expose
    /// only one window get it drawn boldly rather than as a stray hairline.
    var primary: Window? { short ?? long }

    /// The thin inner arc — only when it is genuinely a second reading.
    var secondary: Window? { short == nil ? nil : long }

    static let empty = Usage()

    static func error(_ note: String, rateLimited: Bool = false) -> Usage {
        Usage(note: note, failed: true, rateLimited: rateLimited)
    }
}

enum Service: String, CaseIterable, Identifiable {
    case claude, chatgpt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        }
    }

    /// Brand tint, used while usage is comfortable. Severity takes over later.
    var tint: Color {
        switch self {
        case .claude: .mtClaude
        case .chatgpt: .mtChatGPT
        }
    }
}

