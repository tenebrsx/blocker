import Cocoa

/// Stops a browser Word Blocker can't see into from being used to get around the adult-site block.
///
/// While Word Blocker is running and protection is on, any app that can open web links but isn't a
/// monitored browser is quit on sight (for example a Windows browser running through Parallels, or
/// Tor Browser). Monitored browsers are the ones in `BrowserMonitor.browserBundleIds`, plus their
/// profile and web-app variants (`com.kagi.kagimacOS.<id>`, `com.google.Chrome.app.<id>`).
public final class BrowserLockdown {
    public static let shared = BrowserLockdown()

    private var launchObserver: NSObjectProtocol?
    private var timer: Timer?
    private var lastNoteTime: Date = .distantPast
    private var terminating: Set<pid_t> = []

    private init() {}

    /// True for a browser Word Blocker monitors: a known bundle id or a profile / web-app variant of one.
    public static func isMonitored(_ bundleId: String?) -> Bool {
        guard let id = bundleId else { return false }
        if BrowserMonitor.browserBundleIds.contains(id) { return true }
        return BrowserMonitor.browserBundleIds.contains { id.hasPrefix($0 + ".") }
    }

    public func start() {
        guard launchObserver == nil else { return }
        enforce()

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.enforce()
        }

        // Safety net for anything the launch notification misses (apps that were already running,
        // or that only register as a browser later).
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.enforce() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        launchObserver = nil
        timer?.invalidate()
        timer = nil
    }

    /// Bundle ids of every installed app that can open an https link.
    private func webCapableBundleIds() -> Set<String> {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var ids: Set<String> = []
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            if let id = Bundle(url: appURL)?.bundleIdentifier { ids.insert(id) }
        }
        return ids
    }

    private func enforce() {
        guard WordStore.shared.isEnabled else { return }

        let ownId = Bundle.main.bundleIdentifier
        let webCapable = webCapableBundleIds()
        guard !webCapable.isEmpty else { return }

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  webCapable.contains(id),
                  id != ownId,
                  !id.hasPrefix("com.apple."),          // never touch system apps
                  !BrowserLockdown.isMonitored(id),
                  !terminating.contains(app.processIdentifier) else { continue }
            quit(app)
        }
    }

    private func quit(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "That app"
        terminating.insert(pid)
        app.terminate()

        // A polite quit can be ignored; make sure the browser really goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if !app.isTerminated { app.forceTerminate() }
            self?.terminating.remove(pid)
        }

        let now = Date()
        if WordStore.shared.showWebsiteNotes,
           !MathChallengeController.shared.isActive,
           now.timeIntervalSince(lastNoteTime) > 10 {
            lastNoteTime = now
            InterventionModalController.shared.showBlockedWord(
                word: "",
                note: "\(name) was closed. While Word Blocker is on, only browsers it can monitor are allowed."
            )
        }
    }
}
