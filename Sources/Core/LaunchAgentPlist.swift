import Foundation

/// The launchd definition behind "Start at login, and relaunch if force-quit". Pure Foundation so it can be
/// unit-tested without touching launchd.
public enum LaunchAgentPlist {

    /// - Starts the app at login (`RunAtLoad`).
    /// - Restarts it whenever it exits abnormally (`KeepAlive` / `SuccessfulExit = false`): Force Quit,
    ///   `kill`, a crash. A normal quit exits cleanly, so the quit gate's own exit is not restarted.
    /// - `ThrottleInterval` is how soon a killed app comes back.
    /// - `AbandonProcessGroup` lets the helper that hands the app over (see `LoginItem`) outlive it.
    public static func make(label: String, executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 2,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AbandonProcessGroup": true
        ]
    }

    public static func data(label: String, executable: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: make(label: label, executable: executable), format: .xml, options: 0
        )
    }

    /// True if an existing agent file already says exactly what `make` would write now. Lets an app update
    /// bring an older agent file (a slower restart, a moved app) up to date.
    public static func isCurrent(_ data: Data, label: String, executable: String) -> Bool {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let existing = object as? NSDictionary else { return false }
        return existing.isEqual(to: make(label: label, executable: executable))
    }

    /// The program an existing agent file launches, or nil if the file is not a valid agent.
    public static func executable(in data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    /// Wraps text in single quotes for `/bin/sh` (paths here contain spaces, e.g. "word blocker").
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
