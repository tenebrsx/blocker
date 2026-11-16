import Cocoa

/// Closes Activity Monitor the moment it opens, so it can't be used to Quit or Force Quit Word Blocker.
///
/// This only applies while Word Blocker is running with protection on: turn protection off (or quit
/// Word Blocker), both of which need the math challenge, and Activity Monitor works normally again.
/// Terminal commands such as `kill -9` still send a force-quit; `Guardian` brings the app straight back.
public final class ActivityMonitorBlocker {
    public static let shared = ActivityMonitorBlocker()

    public static let blockedBundleIds = ["com.apple.ActivityMonitor"]

    private var launchObserver: NSObjectProtocol?
    private var timer: Timer?
    private var lastNoteTime: Date = .distantPast

    private init() {}

    public func start() {
        guard launchObserver == nil else { return }
        enforce()

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.enforce()
        }

        // Safety net for a launch the notification misses.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.enforce() }
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

    private func enforce() {
        guard WordStore.shared.isEnabled else { return }

        var closedOne = false
        for id in ActivityMonitorBlocker.blockedBundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                app.forceTerminate()   // Activity Monitor holds nothing worth a polite goodbye
                closedOne = true
            }
        }
        guard closedOne else { return }

        let now = Date()
        if WordStore.shared.showWebsiteNotes,
           !MathChallengeController.shared.isActive,
           now.timeIntervalSince(lastNoteTime) > 10 {
            lastNoteTime = now
            InterventionModalController.shared.showBlockedWord(
                word: "",
                note: "Activity Monitor was closed. It stays closed while Word Blocker is on; turning protection off needs the math challenge."
            )
        }
    }
}
