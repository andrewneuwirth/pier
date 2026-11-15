import Foundation

/// One-time copy of settings (saved Dock values, launch counts...) from the app's previous bundle id. The
/// Application Support folder didn't change, so groups.json and tabs.json carry over on their own.
enum Migration {
    /// The previous bundle id, read from the optional `PierPreviousBundleID` Info.plist key that build.sh
    /// writes from config.local.env; a build without it has nothing to migrate.
    static var oldDomain: String? { Bundle.main.object(forInfoDictionaryKey: "PierPreviousBundleID") as? String }

    /// Flags for things macOS keeps per bundle id (the login item, the Accessibility grant): the new id has to do them again.
    static let perBundle: Set<String> = ["loginItemDefaulted", "askedAccessibility"]

    static func run(into new: UserDefaults = .standard, from old: String? = oldDomain) {
        // persistentDomain reads only that domain's own keys, not the global ones a UserDefaults(suiteName:) would add.
        guard let old, new.string(forKey: "migratedFrom") == nil,
              let keys = UserDefaults.standard.persistentDomain(forName: old), !keys.isEmpty else { return }
        for (k, v) in keys where new.object(forKey: k) == nil && !perBundle.contains(k) { new.set(v, forKey: k) }   // never overwrite
        new.set(old, forKey: "migratedFrom")
    }

    static func selfCheck() {
        func check(_ label: String, _ ok: Bool) { print(ok ? "ok  \(label)" : "FAIL \(label)"); if !ok { exit(1) } }
        let oldName = "pier-selfcheck-old-\(UUID().uuidString)", newName = "pier-selfcheck-new-\(UUID().uuidString)"
        guard let old = UserDefaults(suiteName: oldName), let new = UserDefaults(suiteName: newName) else { return check("migration: suites", false) }
        defer { UserDefaults.standard.removePersistentDomain(forName: oldName); UserDefaults.standard.removePersistentDomain(forName: newName) }
        old.set(["autohide": true], forKey: "savedSystemDock"); old.set(3, forKey: "launches"); new.set(9, forKey: "launches"); old.set(true, forKey: "loginItemDefaulted")
        run(into: new, from: oldName)
        check("migration: copies the old domain once, keeps keys already set, marks it",
              (new.dictionary(forKey: "savedSystemDock")?["autohide"] as? Bool) == true && new.integer(forKey: "launches") == 9
              && new.string(forKey: "migratedFrom") == oldName)
        check("migration: per-bundle flags stay behind, so the login item and Accessibility ask again",
              new.object(forKey: "loginItemDefaulted") == nil)
        new.removeObject(forKey: "savedSystemDock")
        run(into: new, from: oldName)
        check("migration: never runs twice", new.object(forKey: "savedSystemDock") == nil)
        run(into: new, from: nil)
        check("migration: no previous id, nothing happens", new.object(forKey: "savedSystemDock") == nil)
    }
}
