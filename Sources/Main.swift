import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // The guardian is this same program started with --guardian. It must run before anything
        // touches AppKit, so it never shows a Dock icon or a window.
        if CommandLine.arguments.contains(Guardian.argument) {
            Guardian.runGuardian()
        }
        // Unkillable mode's root helper: `WordBlockerWatchdog --watchdog <app path> <user id>`.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: Watchdog.argument), arguments.count > flag + 2,
           let uid = UInt32(arguments[flag + 2]) {
            Watchdog.runWatchdog(appPath: arguments[flag + 1], uid: uid)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// Only one copy may run: two would each watch the keyboard and browsers. During a start-at-login
    /// hand-over the old copy may still be shutting down, so give it a moment before giving up.
    private func exitIfAnotherCopyIsRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        }
        var waited = 0.0
        while !others().isEmpty && waited < 3.0 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        if let existing = others().first {
            existing.activate()
            exit(0)   // status 0: launchd must not restart this duplicate
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        exitIfAnotherCopyIsRunning()
        LoginItem.refreshIfNeeded()

        // Force-quit resilience: ignore polite kill signals, keep a guardian process watching the app,
        // and keep Activity Monitor closed so it can't be used to kill it.
        Guardian.trapTerminationSignals(
            isConfirmed: { MenuBarController.shared.isTerminatingConfirmed },
            terminate: { NSApp.terminate(nil) }
        )
        Guardian.start()
        ActivityMonitorBlocker.shared.start()

        // Run as an accessory app (menu bar agent with window support)
        NSApp.setActivationPolicy(.accessory)

        // Initialize Menu Bar UI
        MenuBarController.shared.setup()

        // Check Permissions and start background engines if already granted
        let granted = PermissionsManager.shared.isAccessibilityGranted()
        print("[Main] Accessibility trusted at launch: \(granted)")
        if granted {
            EventTapManager.shared.start()
            BrowserMonitor.shared.start()
            BrowserLockdown.shared.start()
            ScreenImageScanner.shared.start()
            CinemaModeManager.shared.start()
        }

        // The quit gate is for quitting Word Blocker, not for macOS: never block shutdown, restart or logout.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MenuBarController.shared.isTerminatingConfirmed = true
        }

        // Always bring Preferences window front and center on launch
        showPreferencesWindow()

        // Observe permissions changes in real time
        PermissionsManager.shared.startObserving()
        PermissionsManager.shared.onPermissionStatusChanged = { isNowGranted in
            DispatchQueue.main.async {
                MenuBarController.shared.updateMenuState()
                SettingsWindowController.shared.updatePermissionStatus()
                if isNowGranted {
                    if !EventTapManager.shared.isTapActive {
                        print("[Main] Accessibility granted dynamically. Starting EventTap...")
                        EventTapManager.shared.start()
                    }
                    BrowserMonitor.shared.start()
                    BrowserLockdown.shared.start()
                    ScreenImageScanner.shared.start()
                    CinemaModeManager.shared.start()
                }
            }
        }

        // Listen for enabled / disabled state toggles
        WordStore.shared.onStateChanged = {
            DispatchQueue.main.async {
                if WordStore.shared.isEnabled {
                    BrowserMonitor.shared.start()
                    BrowserLockdown.shared.start()
                    ScreenImageScanner.shared.start()
                } else {
                    BrowserMonitor.shared.stop()
                    BrowserLockdown.shared.stop()
                    ScreenImageScanner.shared.stop()
                }
            }
        }
    }

    /// Handles user double-clicking the app in Finder when it's already running in the background.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferencesWindow()
        return true
    }

    private func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        SettingsWindowController.shared.updatePermissionStatus()
    }

    /// True when this quit request is macOS ending the session (log out, restart, shut down). The quit gate
    /// is for quitting Word Blocker, never for macOS, so it must not hold those up.
    private func systemIsEndingSession() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return false }
        let code = reason.enumCodeValue
        return code == OSType(kAEReallyLogOut) || code == OSType(kAEShutDown) || code == OSType(kAERestart)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MenuBarController.shared.isTerminatingConfirmed || systemIsEndingSession() {
            return .terminateNow
        }
        MenuBarController.shared.confirmAndQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Guardian.prepareForCleanExit()   // a confirmed quit: tell the guardian not to reopen the app
        ActivityMonitorBlocker.shared.stop()
        EventTapManager.shared.stop()
        BrowserMonitor.shared.stop()
        BrowserLockdown.shared.stop()
        ScreenImageScanner.shared.stop()
        CinemaModeManager.shared.stop()
        PermissionsManager.shared.stopObserving()
    }
}
