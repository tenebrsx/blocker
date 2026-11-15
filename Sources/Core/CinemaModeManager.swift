import Cocoa
import ApplicationServices

/// Manages Cinema Mode: detects when media or applications are in full screen,
/// intercepts attempts to exit full screen (Escape, F, Cmd+Ctrl+F, or double-clicking the video),
/// and displays the user's customizable intervention pop-up.
///
/// Everything here is event-driven (called from the event tap). There is deliberately no polling
/// loop and nothing ever toggles full screen back on by itself.
public final class CinemaModeManager {
    public static let shared = CinemaModeManager()

    /// What the user did that would have left full screen.
    public enum ExitTrigger {
        case escapeKey
        case fKey
        case toggleShortcut   // Cmd+Ctrl+F (window-level full screen)
        case doubleClick
    }

    private var isCinemaPromptActive = false
    private var exitCooldownUntil: Date = .distantPast
    private var isObserving = false

    /// Max time any Accessibility query may block the event tap.
    private let axTimeout: Float = 0.08

    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS"
    ]

    private static let mediaPlayerBundleIds: Set<String> = [
        "com.apple.QuickTimePlayerX", "com.apple.TV", "org.videolan.vlc",
        "com.colliderli.iina", "io.mpv", "com.firecore.infuse", "tv.plex.desktop"
    ]

    private init() {}

    public var isPromptActive: Bool { isCinemaPromptActive }

    public func start() {
        guard !isObserving else { return }
        isObserving = true
    }

    public func stop() {
        isObserving = false
    }

    // MARK: - App classification

    public func isBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Self.browserBundleIds.contains(id)
    }

    /// Apps where plain `F` / double-click toggle video full screen.
    public func isMediaCapableApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Self.browserBundleIds.contains(id) || Self.mediaPlayerBundleIds.contains(id)
    }

    // MARK: - Full-screen detection

    /// Checks if the specified (or frontmost) active application has a window in full screen mode.
    public func isFrontAppFullScreen(app: NSRunningApplication? = nil) -> Bool {
        guard let targetApp = app ?? NSWorkspace.shared.frontmostApplication else { return false }
        // WordBlocker itself is not the media app
        if targetApp.processIdentifier == NSRunningApplication.current.processIdentifier {
            return false
        }

        let pid = targetApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, axTimeout)

        var windowVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowVal) != .success || windowVal == nil {
            AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowVal)
        }
        guard let window = windowVal else { return false }
        let win = window as! AXUIElement

        // 1. Check AXFullScreen attribute
        var fsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsVal) == .success,
           let isFs = fsVal as? Bool, isFs {
            return true
        }

        // 2. Check window bounds against screen dimensions (for custom full-screen video players)
        var sizeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeVal) == .success,
           let sVal = sizeVal {
            var size = CGSize.zero
            AXValueGetValue(sVal as! AXValue, .cgSize, &size)
            if let screen = NSScreen.main {
                if size.width >= screen.frame.width - 4 && size.height >= screen.frame.height - 4 {
                    return true
                }
            }
        }

        return false
    }

    /// True when keyboard focus is in a text input (search box, chat, comment field), so a typed
    /// `f` is just a letter and must never be blocked.
    public func isFocusedElementEditable(app: NSRunningApplication? = nil) -> Bool {
        guard let targetApp = app ?? NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(targetApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, axTimeout)

        var focusedVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedVal) == .success,
              let focused = focusedVal else {
            return false
        }
        let element = focused as! AXUIElement

        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
            return true
        }

        // contenteditable regions in browsers report an editable flag
        var editableVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableVal) == .success,
           let editable = editableVal as? Bool, editable {
            return true
        }
        return false
    }

    // MARK: - Intercept

    /// Intercepts the attempt to leave full screen mode.
    /// Returns true if the triggering event should be swallowed/blocked.
    @discardableResult
    public func handleExitAttempt(trigger: ExitTrigger = .escapeKey) -> Bool {
        guard WordStore.shared.isCinemaModeEnabled else { return false }
        guard Date() > exitCooldownUntil else { return false }
        guard !isCinemaPromptActive else { return true }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return false
        }

        isCinemaPromptActive = true

        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }

            InterventionModalController.shared.showCinemaMode(
                note: WordStore.shared.cinemaModeMessage,
                onStay: { [weak self] in
                    guard let self = self else { return }
                    self.isCinemaPromptActive = false
                    if #available(macOS 14.0, *) {
                        frontApp.activate()
                    } else {
                        frontApp.activate(options: .activateIgnoringOtherApps)
                    }
                },
                onExit: { [weak self] in
                    guard let self = self else { return }
                    self.isCinemaPromptActive = false
                    // Cooldown so the synthetic Escape and window transition don't re-trap the user
                    self.exitCooldownUntil = Date().addingTimeInterval(8.0)
                    ActionDispatcher.shared.exitFullScreen(
                        for: frontApp,
                        useNativeFallback: trigger == .toggleShortcut || !self.isBrowser(frontApp)
                    )
                }
            )
        }

        return true
    }
}
