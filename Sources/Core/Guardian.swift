import Foundation
import Darwin

/// Keeps Word Blocker running when someone tries to kill it, for example from Activity Monitor.
///
/// macOS does not let any program catch or refuse a force-quit (SIGKILL), so the protection is that the
/// app comes straight back, from three directions at once:
///
/// 1. **Polite quits are ignored.** SIGTERM, SIGINT, SIGHUP and SIGQUIT (Activity Monitor's "Quit",
///    `kill`, `killall`, Terminal's Ctrl-C) do nothing until the quit gate's math challenge has been
///    passed. Only SIGKILL and SIGSTOP are left, and those can't be stopped by any app.
/// 2. **A guardian process.** The app starts a second copy of itself (`WordBlocker --guardian`) that does
///    nothing but watch the app. If the app disappears without a confirmed quit, the guardian reopens it
///    within about half a second. The app watches the guardian the same way and restarts it if it is
///    killed, so killing either one just brings the other back. A frozen (SIGSTOP) process is resumed.
/// 3. **launchd.** With "Start at login, and relaunch if force-quit" on, launchd restarts the app too
///    (see `LoginItem`). That is what covers the case where both processes are killed at the same moment.
///
/// A confirmed quit (the math challenge, or macOS shutting down) calls `prepareForCleanExit()`, which
/// leaves a marker the guardian sees before it exits, so the guardian never fights a real quit.
public enum Guardian {
    /// The argument that makes the app run as the guardian instead of as the menu-bar app.
    public static let argument = "--guardian"

    /// Where the pid files and the quit marker live. One folder per bundle id, so a differently-signed
    /// copy of the app never touches the real one's files. Tests point this somewhere else.
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "WordBlocker"
        return base.appendingPathComponent("WordBlocker/run/\(id)", isDirectory: true)
    }()

    static var appPidFile: URL { directory.appendingPathComponent("app.pid") }
    static var guardianPidFile: URL { directory.appendingPathComponent("guardian.pid") }
    static var quittingMarker: URL { directory.appendingPathComponent("quitting") }

    // MARK: - Process helpers (pure, unit-tested)

    /// The process id in a pid file, or nil if the text isn't a usable pid.
    public static func parsePid(_ text: String) -> pid_t? {
        guard let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 else { return nil }
        return value
    }

    static func readPid(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parsePid(text)
    }

    static func writePid(_ pid: pid_t, to url: URL) {
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    /// True if a process with this id exists (even one we aren't allowed to signal).
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// True if the process is alive and is this same program. Guards against an old pid file whose
    /// number has since been given to something unrelated, and treats a zombie as dead.
    public static func isOurs(_ pid: pid_t) -> Bool {
        guard isAlive(pid) else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        guard let mine = Bundle.main.executablePath else { return true }
        let theirs = String(cString: buffer)
        return (theirs as NSString).lastPathComponent == (mine as NSString).lastPathComponent
    }

    // MARK: - The menu-bar app's side

    private static var tick: DispatchSourceTimer?
    private static var guardianProcess: Process?
    private static var lastSpawn = Date.distantPast
    private static var quitting = false
    private static var signalSources: [DispatchSourceSignal] = []

    /// Records this process as the app and makes sure a guardian is watching it. Call once, after the
    /// single-copy check, so a duplicate that is about to exit never gets in the guardian's way.
    public static func start() {
        quitting = false
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: quittingMarker)
        writePid(getpid(), to: appPidFile)
        ensureGuardian()

        guard tick == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { watch() }
        timer.resume()
        tick = timer
    }

    /// Once a second: keep the guardian alive and our own records correct.
    private static func watch() {
        guard !quitting else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: quittingMarker.path) {
            try? fileManager.removeItem(at: quittingMarker)   // nobody confirmed a quit; the marker is stale
        }
        if readPid(appPidFile) != getpid() { writePid(getpid(), to: appPidFile) }
        ensureGuardian()
    }

    private static func ensureGuardian() {
        guard !quitting else { return }
        if let pid = readPid(guardianPidFile), isOurs(pid) {
            kill(pid, SIGCONT)   // un-freezes a guardian that was stopped; does nothing to a running one
            return
        }
        guard Date().timeIntervalSince(lastSpawn) > 2 else { return }
        lastSpawn = Date()
        spawnGuardian()
    }

    private static func spawnGuardian() {
        guard let executable = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            guardianProcess = process   // kept so Foundation reaps it if it ever exits
            writePid(process.processIdentifier, to: guardianPidFile)
        } catch {
            print("[Guardian] Could not start the guardian: \(error)")
        }
    }

    /// Call when the app is about to exit for a reason the user confirmed (math challenge, shutdown,
    /// hand-over to launchd). The guardian sees the marker and exits instead of reopening the app.
    public static func prepareForCleanExit() {
        quitting = true
        tick?.cancel()
        tick = nil
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: quittingMarker.path, contents: Data())
    }

    /// Makes the app ignore every signal that asks it to quit, unless a quit has been confirmed.
    /// (SIGKILL and SIGSTOP can't be caught by anything; the guardian handles those.)
    public static func trapTerminationSignals(isConfirmed: @escaping () -> Bool, terminate: @escaping () -> Void) {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                if isConfirmed() {
                    terminate()
                } else {
                    print("[Guardian] Ignored signal \(number): quitting needs the math challenge")
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - The guardian process

    /// Runs as the guardian: reopens the app whenever it vanishes without a confirmed quit. Never returns.
    /// Touches no AppKit, so it shows no Dock icon or window.
    public static func runGuardian() -> Never {
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { signal(number, SIG_IGN) }

        let me = getpid()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let other = readPid(guardianPidFile), other != me, isOurs(other) { exit(0) }   // already guarded
        writePid(me, to: guardianPidFile)

        var lastLaunch = Date.distantPast
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4, leeway: .milliseconds(150))
        timer.setEventHandler {
            let fileManager = FileManager.default

            // A confirmed quit: step aside.
            if fileManager.fileExists(atPath: quittingMarker.path) {
                if readPid(guardianPidFile) == me { try? fileManager.removeItem(at: guardianPidFile) }
                exit(0)
            }

            // Only one guardian: if another one has taken over, leave it to it.
            if let recorded = readPid(guardianPidFile) {
                if recorded != me {
                    if isOurs(recorded) { exit(0) }
                    writePid(me, to: guardianPidFile)
                }
            } else {
                writePid(me, to: guardianPidFile)
            }

            // The app is there: make sure it isn't frozen, and carry on.
            if let app = readPid(appPidFile), isOurs(app) {
                kill(app, SIGCONT)
                return
            }

            // The app is gone and nobody confirmed a quit: bring it back (not more than once every 4s).
            guard Date().timeIntervalSince(lastLaunch) > 4 else { return }
            lastLaunch = Date()
            relaunchApp()
        }
        timer.resume()
        dispatchMain()
    }

    private static func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [Bundle.main.bundlePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { print("[Guardian] Could not reopen the app: \(error)") }
    }
}
