import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app (menu bar agent with window support)
        NSApp.setActivationPolicy(.accessory)

        // Initialize Menu Bar UI
        MenuBarController.shared.setup()

        // Check Permissions and start background engines if already granted
        let granted = PermissionsManager.shared.isAccessibilityGranted()
        if granted {
            EventTapManager.shared.start()
            BrowserMonitor.shared.start()
            BrowserLockdown.shared.start()
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
                } else {
                    BrowserMonitor.shared.stop()
                    BrowserLockdown.shared.stop()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MenuBarController.shared.isTerminatingConfirmed {
            return .terminateNow
        }
        MenuBarController.shared.confirmAndQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        EventTapManager.shared.stop()
        BrowserMonitor.shared.stop()
        BrowserLockdown.shared.stop()
        CinemaModeManager.shared.stop()
        PermissionsManager.shared.stopObserving()
    }
}
