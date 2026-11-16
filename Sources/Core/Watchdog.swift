import Foundation
import Darwin

/// "Unkillable mode": a tiny helper that runs as **root**, so a normal user (Activity Monitor, `kill -9`,
/// Terminal) cannot kill it. Its only job is to reopen Word Blocker, within about half a second, whenever
/// the app is not running.
///
/// Why it has to be root: macOS lets any program owned by you be killed by you, with no way for the program
/// to refuse. A root-owned process can't be killed by an ordinary account at all (Activity Monitor asks for
/// an administrator password first). So the app itself can still be force-quit, but it comes straight back,
/// and the thing that brings it back can't be killed without the Mac's admin password.
///
/// Installing needs that password once (macOS shows its own prompt; Word Blocker never sees it). The helper
/// is installed as a LaunchDaemon (`/Library/LaunchDaemons/com.wordblocker.watchdog.plist`) that runs a
/// root-owned copy of this program (`WordBlockerWatchdog --watchdog <app> <uid>`), kept outside the app
/// bundle so a user-writable file is never what runs as root.
///
/// Quitting Word Blocker while this is installed needs the math challenge AND the admin password: the quit
/// stops the helper first (`stopForQuit`), otherwise it would just reopen the app. Turning the mode off
/// needs the math challenge and the password too (`uninstall`).
public enum Watchdog {
    /// The argument that makes the program run as the root watchdog instead of the menu-bar app.
    public static let argument = "--watchdog"

    public static let label = "com.wordblocker.watchdog"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let installDirectory = "/Library/Application Support/WordBlocker"
    public static let installedExecutable = installDirectory + "/WordBlockerWatchdog"

    /// True when the helper's launch daemon file exists (readable by everyone).
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    // MARK: - Installer text (pure, unit-tested)

    /// launchd definition: runs at boot, and is restarted at once if it ever exits.
    public static func plist(executable: String, appPath: String, uid: uid_t) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, argument, appPath, String(uid)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 1
        ]
    }

    public static func plistData(executable: String, appPath: String, uid: uid_t) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable, appPath: appPath, uid: uid), format: .xml, options: 0
        )
    }

    /// The commands that install the helper, run once as root. The launchd file is carried inside the
    /// command itself (base64), never through a temporary file another program could swap. If any step
    /// fails everything is removed again, so a failed install leaves nothing half-installed.
    public static func installScript(sourceExecutable: String, appPath: String, uid: uid_t) throws -> String {
        let encoded = try plistData(executable: installedExecutable, appPath: appPath, uid: uid)
            .base64EncodedString()
        let q = LaunchAgentPlist.shellQuote
        return [
            "set -e",
            "P=\(q(plistPath))",
            "D=\(q(installDirectory))",
            "trap 'if [ $? -ne 0 ]; then /bin/rm -f \"$P\"; /bin/rm -rf \"$D\"; fi' EXIT",
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/mkdir -p \"$D\"",
            "/bin/cp -f \(q(sourceExecutable)) \(q(installedExecutable))",
            "/usr/sbin/chown -R root:wheel \"$D\"",
            "/bin/chmod 755 \"$D\" \(q(installedExecutable))",
            "echo \(q(encoded)) | /usr/bin/base64 -D > \"$P\"",
            "/usr/sbin/chown root:wheel \"$P\"",
            "/bin/chmod 644 \"$P\"",
            "/usr/bin/plutil -lint \"$P\" >/dev/null",
            "/bin/launchctl bootstrap system \"$P\""
        ].joined(separator: "; ")
    }

    /// Stops the helper for this session. The files stay, so it starts again at the next boot.
    public static let stopScript = "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true"

    /// Stops the helper and removes everything it installed.
    public static let uninstallScript = [
        "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
        "/bin/rm -f \(LaunchAgentPlist.shellQuote(plistPath))",
        "/bin/rm -rf \(LaunchAgentPlist.shellQuote(installDirectory))"
    ].joined(separator: "; ")

    /// AppleScript that runs a shell command as administrator; macOS shows its own password / Touch ID
    /// prompt for it.
    public static func appleScript(running shellScript: String) -> String {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Installing (shows the macOS administrator prompt; never call on the main thread)

    private static func runAsAdmin(_ shellScript: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(running: shellScript)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0   // non-zero: wrong password, cancelled, or not an admin
    }

    /// Installs and starts the helper for the app at this path. False if the prompt was cancelled or failed.
    public static func install() -> Bool {
        guard let executable = Bundle.main.executablePath,
              Bundle.main.bundlePath.hasSuffix(".app"),
              let script = try? installScript(
                sourceExecutable: executable, appPath: Bundle.main.bundlePath, uid: getuid()
              ) else { return false }
        return runAsAdmin(script)
    }

    public static func uninstall() -> Bool { runAsAdmin(uninstallScript) }

    /// Stops the helper so a confirmed quit can stick. False if the prompt was cancelled.
    public static func stopForQuit() -> Bool { runAsAdmin(stopScript) }

    // MARK: - Finding processes

    /// The user id that owns the screen right now (0 at the login window), from who owns /dev/console.
    static func consoleUser() -> uid_t? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return nil }
        return uid_t(owner.uint32Value)
    }

    /// Process ids owned by `uid` whose program is exactly `path`. A zombie has no path and doesn't count.
    static func pids(ofExecutable path: String, owner uid: uid_t) -> [pid_t] {
        let uidOnly: UInt32 = 4   // PROC_UID_ONLY in <sys/proc_info.h>
        let bytes = proc_listpids(uidOnly, uid, nil, 0)
        guard bytes > 0 else { return [] }
        var list = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let written = proc_listpids(uidOnly, uid, &list, Int32(list.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }

        var found: [pid_t] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in list.prefix(Int(written) / MemoryLayout<pid_t>.size) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == path {
                found.append(pid)
            }
        }
        return found
    }

    // MARK: - The watchdog process

    /// Runs as the watchdog (as root once installed): reopens the app whenever it is not running while its
    /// owner is at the screen. Never returns. SIGTERM is left alone on purpose so macOS can stop it at shutdown.
    public static func runWatchdog(appPath: String, uid: uid_t) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let executable = appPath + "/Contents/MacOS/WordBlocker"

        var lastLaunch = Date.distantPast
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(150))
        timer.setEventHandler {
            guard consoleUser() == uid else { return }   // logged out, locked out, or someone else's turn

            let running = pids(ofExecutable: executable, owner: uid)
            if !running.isEmpty {
                for pid in running { kill(pid, SIGCONT) }   // un-freezes an app stopped with SIGSTOP
                return
            }

            guard Date().timeIntervalSince(lastLaunch) > 3 else { return }
            lastLaunch = Date()
            launchApp(appPath: appPath, uid: uid)
        }
        timer.resume()
        dispatchMain()
    }

    private static func launchApp(appPath: String, uid: uid_t) {
        let process = Process()
        if geteuid() == 0 {
            // As root, open the app inside the user's own login session.
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["asuser", String(uid), "/usr/bin/open", appPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [appPath]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { print("[Watchdog] Could not reopen the app: \(error)") }
    }
}
