import Cocoa

/// "Start at login, and relaunch if force-quit", done with a per-user launch agent
/// (`~/Library/LaunchAgents/com.wordblocker.app.agent.plist`). No admin rights and no Apple developer
/// account are needed.
///
/// Turning it on or off restarts Word Blocker once, so that the running copy is the one launchd manages.
/// The restart is done by a short-lived shell command that outlives the app, with a fallback that simply
/// reopens the app if launchd refuses the agent, so the app can never be left closed by a failed switch.
public enum LoginItem {
    public static let label = "com.wordblocker.app.agent"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// True when the launch agent file exists.
    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func writePlist() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try LaunchAgentPlist.data(label: label, executable: executable).write(to: plistURL, options: .atomic)
            return true
        } catch {
            print("[LoginItem] Could not write \(plistURL.path): \(error)")
            return false
        }
    }

    /// If the agent file is out of date (the app has moved, or an update changed what the agent should
    /// say), rewrite it for the current copy. Takes effect at the next login.
    public static func refreshIfNeeded() {
        guard isEnabled,
              let executable = Bundle.main.executablePath,
              let data = try? Data(contentsOf: plistURL),
              !LaunchAgentPlist.isCurrent(data, label: label, executable: executable) else { return }
        _ = writePlist()
    }

    /// Installs the agent and restarts the app under it. Returns false (and changes nothing) if the agent
    /// file can't be written.
    public static func enableAndRestart() -> Bool {
        guard writePlist() else { return false }
        let domain = "gui/\(getuid())"
        let plist = LaunchAgentPlist.shellQuote(plistURL.path)
        let bundle = LaunchAgentPlist.shellQuote(Bundle.main.bundlePath)
        runDetached(
            "sleep 2; /bin/launchctl bootout \(domain)/\(label) >/dev/null 2>&1; "
            + "/bin/launchctl bootstrap \(domain) \(plist) || /usr/bin/open \(bundle)"
        )
        quitForHandOver()
        return true
    }

    /// Removes the agent and restarts the app on its own, so it is no longer restarted when killed.
    public static func disableAndRestart() {
        try? FileManager.default.removeItem(at: plistURL)
        let domain = "gui/\(getuid())"
        let bundle = LaunchAgentPlist.shellQuote(Bundle.main.bundlePath)
        runDetached(
            "sleep 1; /bin/launchctl bootout \(domain)/\(label) >/dev/null 2>&1; sleep 1; /usr/bin/open \(bundle)"
        )
        quitForHandOver()
    }

    /// Runs a shell command that keeps going after this app exits.
    private static func runDetached(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { print("[LoginItem] Could not start the hand-over: \(error)") }
    }

    /// A clean exit (status 0), so launchd does not treat the hand-over as a crash.
    private static func quitForHandOver() {
        MenuBarController.shared.isTerminatingConfirmed = true
        NSApp.terminate(nil)
    }
}
