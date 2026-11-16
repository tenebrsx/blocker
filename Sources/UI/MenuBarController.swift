import Cocoa

/// Manages the macOS menu bar status item, context menu, and custom quit confirmation.
public final class MenuBarController {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var listMenuItem: NSMenuItem!
    private var scannerMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var cinemaMenuItem: NSMenuItem!
    public var isTerminatingConfirmed = false

    private init() {}

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🛡️"
            button.toolTip = "Word Blocker (macOS Background Agent)"
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Initializing...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        listMenuItem = NSMenuItem(title: AdultDomainList.shared.statusText, action: nil, keyEquivalent: "")
        listMenuItem.isEnabled = false
        menu.addItem(listMenuItem)
        AdultDomainList.shared.onChange = { [weak self] in self?.updateMenuState() }

        scannerMenuItem = NSMenuItem(title: ScreenImageScanner.shared.statusText, action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        scannerMenuItem.target = self
        menu.addItem(scannerMenuItem)
        ScreenImageScanner.shared.onChange = { [weak self] in self?.updateMenuState() }

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Protection Enabled", action: #selector(toggleProtection), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        cinemaMenuItem = NSMenuItem(title: "🎬 Cinema Mode", action: #selector(toggleCinemaMode), keyEquivalent: "")
        cinemaMenuItem.target = self
        menu.addItem(cinemaMenuItem)

        let settingsItem = NSMenuItem(title: "Preferences & Blocked Words...", action: #selector(openPreferences), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionItem = NSMenuItem(title: "Accessibility Settings...", action: #selector(openAccessibility), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Word Blocker", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        updateMenuState()

        WordStore.shared.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuState()
            }
        }

        WordStore.shared.onCinemaModeChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuState()
            }
        }
    }

    public func updateMenuState() {
        let isEnabled = WordStore.shared.isEnabled
        let hasPermission = PermissionsManager.shared.isAccessibilityGranted()

        if !hasPermission {
            statusMenuItem.title = "⚠️ Status: Accessibility Required"
            if let button = statusItem?.button {
                button.title = "⚠️"
            }
        } else if isEnabled {
            statusMenuItem.title = "🟢 Status: Active (Blocking)"
            if let button = statusItem?.button {
                button.title = "🛡️"
            }
        } else {
            statusMenuItem.title = "⚪ Status: Paused"
            if let button = statusItem?.button {
                button.title = "🛡️(Off)"
            }
        }

        listMenuItem?.title = AdultDomainList.shared.statusText
        scannerMenuItem?.title = ScreenImageScanner.shared.statusText
        scannerMenuItem?.isEnabled = ScreenImageScanner.shared.status == .needsPermission

        toggleMenuItem.state = isEnabled ? .on : .off
        toggleMenuItem.title = isEnabled ? "Protection Enabled" : "Protection Disabled"

        let isCinema = WordStore.shared.isCinemaModeEnabled
        cinemaMenuItem?.state = isCinema ? .on : .off
        cinemaMenuItem?.title = isCinema ? "🎬 Cinema Mode: Active" : "🎬 Cinema Mode: Disabled"
    }

    @objc private func toggleCinemaMode() {
        WordStore.shared.isCinemaModeEnabled.toggle()
        updateMenuState()
        if WordStore.shared.isCinemaModeEnabled {
            CinemaModeManager.shared.start()
        }
    }

    @objc private func toggleProtection() {
        if WordStore.shared.isEnabled {
            // Intercept attempt to disable protection
            confirmAndDisable()
        } else {
            // Enable silently without pop-up message
            WordStore.shared.isEnabled = true
            updateMenuState()
        }
    }

    /// Displays the user's custom disable intervention prompt using the centered intervention modal.
    public func confirmAndDisable(completion: ((Bool) -> Void)? = nil) {
        InterventionModalController.shared.showDisableProtection(
            message: WordStore.shared.disableProtectionMessage,
            onKeepOn: { [weak self] in
                self?.updateMenuState()
                completion?(false)
            },
            onDisable: { [weak self] in
                // Turning protection off is as serious as quitting, so it needs the full challenge.
                MathChallengeController.shared.present(
                    title: "Disable protection",
                    reason: "Solve \(MathChallenge.strictProblemCount) problems in a row to turn protection off.",
                    problemCount: MathChallenge.strictProblemCount
                ) { passed in
                    if passed { WordStore.shared.isEnabled = false }
                    self?.updateMenuState()
                    completion?(passed)
                }
            }
        )
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibility() {
        PermissionsManager.shared.openSystemSettingsAccessibility()
    }

    @objc private func quitApp() {
        confirmAndQuit()
    }

    /// Displays the user's custom quit intervention prompt using the centered intervention modal.
    public func confirmAndQuit() {
        InterventionModalController.shared.showQuitApp(
            message: WordStore.shared.quitMessage,
            onStay: {},
            onQuit: { [weak self] in
                MathChallengeController.shared.present(
                    title: "Quit",
                    reason: "Solve \(MathChallenge.strictProblemCount) problems in a row to quit Word Blocker. Protection stops when it quits.",
                    problemCount: MathChallenge.strictProblemCount
                ) { passed in
                    guard passed else { return }
                    self?.isTerminatingConfirmed = true
                    NSApp.terminate(nil)
                }
            }
        )
    }
}
