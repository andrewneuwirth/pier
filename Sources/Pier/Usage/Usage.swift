import Foundation

/// One rate-limit window as both services report it: how much of the allowance
/// is spent, and when it comes back.
struct UsageWindow: Equatable {
    var percent: Double
    var resetsAt: Date?
}

/// One service's reading. Either window can be absent (plans differ in which
/// ones they expose); a missing window is left undrawn rather than a confident zero.
struct Usage: Equatable {
    var short: UsageWindow?     // the window you bump into mid-session
    var long: UsageWindow?      // the multi-day one
    var note: String?           // plan name, or why there is nothing to show
    var failed = false
    var fetchedAt: Date?        // when this reading actually came off the wire
    var stale = false           // held over because a later refresh was refused
    var holdReason: String?     // and what the refusal said, verbatim
    var rateLimited = false     // the refusal was a 429, so back off harder

    static func error(_ note: String, rateLimited: Bool = false) -> Usage {
        Usage(note: note, failed: true, rateLimited: rateLimited)
    }
}

enum UsageService: CaseIterable {
    case claude, chatgpt
}
