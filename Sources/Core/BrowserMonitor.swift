import Cocoa
import ApplicationServices

/// Monitors active web browser windows across Safari, Chrome, Arc, Brave, Edge, Firefox, Opera, and Vivaldi.
/// When a blocked domain is detected in the active browser, it immediately triggers the custom pop-up note
/// and optionally closes the offending tab.
public final class BrowserMonitor {
    public static let shared = BrowserMonitor()

    public static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "net.waterfox.waterfox",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS", // Orion
        "com.duckduckgo.macos.browser",
        "ai.perplexity.comet",
        "com.sigmaos.sigmaos.macos"
    ]

    private var supportedBrowsers: Set<String> { BrowserMonitor.browserBundleIds }

    private var pollTimer: Timer?
    private var isMonitoring = false
    private var lastBlockedDomain: String?
    private var lastBlockedTime: Date = .distantPast
    private var axEnabledPids: Set<pid_t> = []

    /// Accessibility reads run here, never on the main thread. A browser that is busy loading a page
    /// can stall AX calls for seconds; on the main thread that froze the poll timer (and the keyboard
    /// event tap) and is the main reason blocks arrived late or not at all.
    private let scanQueue = DispatchQueue(label: "com.wordblocker.browserscan", qos: .userInitiated)
    private var scanInFlight = false        // main thread only
    private var rescanRequested = false     // main thread only

    /// Push notifications from the frontmost browser (title / window / page-load changes) so a
    /// navigation is checked the moment it happens instead of waiting for the next poll tick.
    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0

    /// Keeps macOS App Nap from throttling our timers while we sit in the menu bar.
    /// Without this, background polling slowed to once every several seconds or more.
    /// (Deliberately not `.latencyCritical`: that also switches off timer coalescing, which costs battery
    /// and isn't needed here. Keystrokes arrive through the event tap, not a timer.)
    private var activityToken: NSObjectProtocol?

    /// How often the fallback poll runs. Fast while a browser is in front, where a missed navigation
    /// matters; slow otherwise, because switching to a browser is announced by `appActivated` anyway and
    /// each tick costs a Launch Services lookup. Stays fast while a gate prompt is up so its state is
    /// reconciled promptly.
    private static let activePollInterval: TimeInterval = 0.3
    private static let idlePollInterval: TimeInterval = 1.5
    private var pollInterval: TimeInterval = BrowserMonitor.activePollInterval

    /// Active timers for temporarily allowed websites. When a timer expires, it revokes the allowance
    /// and automatically closes all tabs of that domain, regardless of where the user is in the browser.
    private var allowanceTimers: [String: Timer] = [:]

    private init() {}

    /// Starts monitoring browser activity.
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Downloads / loads the large adult-site blocklists in the background (no-op if already running).
        AdultDomainList.shared.start()

        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Word Blocker is monitoring browsers for blocked websites"
            )
        }

        // Bound every Accessibility call (default is ~6s) so one unresponsive browser can't stall scans.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Fallback poll in .common mode (keeps firing during menu/modal tracking). The AX observer
        // catches most navigations instantly; this covers anything it misses.
        pollInterval = BrowserMonitor.activePollInterval
        installPollTimer()
        inspectActiveBrowser()
    }

    private func installPollTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.inspectActiveBrowser()
        }
        timer.tolerance = pollInterval / 6   // 0.05s at 0.3s, 0.25s at 1.5s
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Switches the fallback poll between its fast and slow rate. No-op when the rate is already right.
    private func setPollInterval(_ interval: TimeInterval) {
        guard isMonitoring, interval != pollInterval else { return }
        pollInterval = interval
        installPollTimer()
    }

    /// Stops monitoring browser activity.
    public func stop() {
        isMonitoring = false
        pollTimer?.invalidate()
        pollTimer = nil
        clearAllAllowanceTimers()
        detachObserver()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        // Check immediately on switching apps instead of waiting for the next tick.
        DispatchQueue.main.async { [weak self] in self?.inspectActiveBrowser() }
    }

    // MARK: - AX observer (instant navigation detection)

    private func attachObserver(pid: pid_t) {
        guard observedPid != pid else { return }
        detachObserver()

        let callback: AXObserverCallback = { _, _, _, _ in
            DispatchQueue.main.async { BrowserMonitor.shared.inspectActiveBrowser() }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let obs = observer else { return }

        let appRef = AXUIElementCreateApplication(pid)
        let notifications = [
            kAXTitleChangedNotification,          // tab/page title changes on every navigation
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowCreatedNotification,
            "AXLoadComplete"                      // Chromium/WebKit page finished loading
        ]
        for name in notifications {
            AXObserverAddNotification(obs, appRef, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        axObserver = obs
        observedPid = pid
    }

    private func detachObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        axObserver = nil
        observedPid = 0
    }

    private var isGatePromptActive = false
    private var gatePromptShownAt: Date = .distantPast

    /// Clears the gate flag if the gate is no longer actually on screen (replaced by another alert,
    /// closed some other way, etc.). This is what previously left blocking dead until an app restart.
    private func reconcileGateState() {
        guard isGatePromptActive else { return }
        let controller = InterventionModalController.shared
        let onScreen = (controller.isShowingBlockedWebsite && controller.isPanelVisible)
            || MathChallengeController.shared.isActive
        if !onScreen && Date().timeIntervalSince(gatePromptShownAt) > 1.0 {
            isGatePromptActive = false
            lastBlockedDomain = nil
        }
    }

    /// Inspects the frontmost browser for blocked websites. Cheap on the main thread: the AX reads
    /// happen on `scanQueue`, and overlapping requests are coalesced into one follow-up scan.
    public func inspectActiveBrowser() {
        guard isMonitoring, WordStore.shared.isEnabled else { return }
        reconcileGateState()

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier,
              BrowserLockdown.isMonitored(bundleId) else {
            frontPageURL = nil
            // Nothing to scan: poll slowly. Switching to a browser fires `appActivated`, which checks at once.
            setPollInterval(isGatePromptActive ? BrowserMonitor.activePollInterval : BrowserMonitor.idlePollInterval)
            return
        }

        setPollInterval(BrowserMonitor.activePollInterval)
        let pid = frontApp.processIdentifier
        attachObserver(pid: pid)
        // Scanning never pauses, even with a pop-up on screen: adult sites must be caught at all times,
        // and with auto-close on, ignoring a social pop-up can't leave the page usable.
        // `evaluate` decides what to do with the result.

        if scanInFlight {
            rescanRequested = true
            return
        }
        scanInFlight = true

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            self.enableAccessibilityIfNeeded(pid: pid)
            let appRef = AXUIElementCreateApplication(pid)
            var found: [ScanHit] = []
            for (window, isFocused) in self.browserWindows(pid: pid) {
                let url = self.extractURL(from: window, appRef: appRef)
                let title = self.windowTitle(window)
                // When a browser won't reveal its address (some full-screen / unusual windows), keep the
                // window anyway if its title names an adult site, so it can still be caught.
                if url != nil || AdultSiteMatcher.isAdultTitle(title ?? "") {
                    found.append(ScanHit(window: window, isFocused: isFocused, url: url ?? "", title: title))
                }
            }

            DispatchQueue.main.async {
                self.scanInFlight = false
                // Only act if that browser is still the frontmost app.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    // The page in front, for the screen scanner (it leaves everyday sites alone).
                    let focusedURL = found.first(where: { $0.isFocused })?.url
                    self.frontPageURL = (focusedURL?.isEmpty ?? true) ? nil : focusedURL
                    self.evaluate(found, pid: pid, bundleId: bundleId)
                    self.scheduleContentScan(found, pid: pid, bundleId: bundleId)
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.inspectActiveBrowser()
                }
            }
        }
    }

    private struct ScanHit {
        let window: AXUIElement
        let isFocused: Bool
        let url: String
        let title: String?
    }

    /// Exactly which page was blocked: used so "Leave Tab" closes that tab and nothing else.
    private struct BlockTarget {
        let domain: String
        let pid: pid_t
        let bundleId: String
        let window: AXUIElement
        let title: String?   // tab title at detection time (window title == active tab title)
    }

    /// The address of the page in front in the frontmost browser, nil when a browser isn't in front or its
    /// address can't be read. Main thread only. The screen scanner uses it to skip everyday sites.
    public private(set) var frontPageURL: String?

    /// True while a "Leave Tab" close is in progress. Detection is paused so the page that is
    /// about to be closed can't trigger a second pop-up.
    private var isLeaving = false

    /// Main-thread decision step for URLs collected by a scan.
    private func evaluate(_ found: [ScanHit], pid: pid_t, bundleId: String) {
        guard isMonitoring, WordStore.shared.isEnabled, !isLeaving else { return }

        // Adult sites come first and are a hard block: checked before (and independent of) the user's
        // list, ignoring temporary allowances, math unlocks and the auto-close setting.
        for hit in found where AdultSiteMatcher.isAdult(urlOrHost: hit.url)
            || AdultSiteMatcher.isAdultSearch(urlOrHost: hit.url)
            || AdultSiteMatcher.isAdultCommunityPage(urlOrHost: hit.url)
            || (hit.url.isEmpty && AdultSiteMatcher.isAdultTitle(hit.title ?? "")) {
            blockAdultSite(hit, pid: pid, bundleId: bundleId)
            return
        }

        if isGatePromptActive && !WordStore.shared.closeBlockedTabs { return }

        // Focused window first, then the browser's other windows (second monitor, split view).
        for hit in found {
            guard let match = WordStore.shared.matchBlockedWebsite(urlOrHost: hit.url) else { continue }
            if WordStore.shared.isWebsiteTemporarilyAllowed(match.matchedDomain) { continue }

            if isGatePromptActive {
                // A pop-up or math challenge is already on screen and auto-close is on: don't stack a
                // second pop-up, just close the blocked tab again.
                leaveTab(BlockTarget(domain: match.matchedDomain, pid: pid, bundleId: bundleId,
                                     window: hit.window, title: hit.title))
                return
            }

            let now = Date()
            if let lastDomain = lastBlockedDomain,
               lastDomain == match.matchedDomain,
               now.timeIntervalSince(lastBlockedTime) < 2.0 {
                return
            }

            if !hit.isFocused {
                // Bring the offending window forward so "Leave Tab" closes the right tab.
                AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(hit.window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }

            lastBlockedDomain = match.matchedDomain
            lastBlockedTime = now

            let target = BlockTarget(domain: match.matchedDomain, pid: pid, bundleId: bundleId,
                                     window: hit.window, title: hit.title)
            if WordStore.shared.requireAllowToEnter {
                showAccessGatePrompt(note: match.note, target: target)
            } else {
                handleBlockedWebsiteDetected(note: match.note, target: target)
            }
            return
        }
    }

    private var lastAdultNoteTime: Date = .distantPast

    /// Hard block for a built-in adult site: the tab is always closed. There is no "Allow" button here.
    private func blockAdultSite(_ hit: ScanHit, pid: pid_t, bundleId: String) {
        // What identifies the offending tab: the host for an adult site, but the full address for an adult
        // search, so only that page closes (not every tab on the search engine). No address at all means
        // it was caught by its title, and the front tab is closed directly.
        let key: String
        if hit.url.isEmpty {
            key = ""
        } else if AdultSiteMatcher.isAdult(urlOrHost: hit.url) {
            key = AdultSiteMatcher.host(from: hit.url) ?? hit.url
        } else {
            key = hit.url
        }
        let domain = WordStore.shared.normalizeWebsiteInput(key)
        let target = BlockTarget(domain: domain, pid: pid, bundleId: bundleId,
                                 window: hit.window, title: hit.title)

        // Which check fired, and which rule inside it, for the block log.
        if hit.url.isEmpty {
            if let reason = AdultSiteMatcher.adultTitleReason(hit.title ?? "") {
                BlockLog.record(BlockEvent.website(check: "adult-title", reason: reason, page: nil, app: bundleId))
            }
        } else {
            let page = BlockLog.describePage(hit.url)
            if let reason = AdultSiteMatcher.adultSiteReason(urlOrHost: hit.url) {
                BlockLog.record(BlockEvent.website(check: "adult-site", reason: reason, page: page, app: bundleId))
            } else if let reason = AdultSiteMatcher.adultSearchReason(urlOrHost: hit.url) {
                BlockLog.record(BlockEvent.website(check: "adult-search", reason: reason, page: page, app: bundleId))
            } else if let reason = AdultSiteMatcher.adultCommunityReason(urlOrHost: hit.url) {
                BlockLog.record(BlockEvent.website(check: "adult-community", reason: reason, page: page, app: bundleId))
            }
        }

        showAdultNote()

        // Matching tabs by address is only safe for a non-empty key that can sit inside an AppleScript string.
        if !domain.isEmpty, !domain.contains("\""), !domain.contains("\\") {
            leaveTab(target)
        } else {
            closeFrontTab(hit, bundleId: bundleId)
        }
    }

    /// A short note, but never on top of a social pop-up or math challenge, and not on every rescan.
    private func showAdultNote(_ message: String = "This website is permanently blocked. There is no way through.") {
        let now = Date()
        guard WordStore.shared.showWebsiteNotes, !isGatePromptActive, !MathChallengeController.shared.isActive,
              now.timeIntervalSince(lastAdultNoteTime) > 10 else { return }
        lastAdultNoteTime = now
        InterventionModalController.shared.showBlockedWord(word: "", note: message)
    }

    // MARK: - Page content scan (safety net for adult pages on sites no list knows)

    private let contentQueue = DispatchQueue(label: "com.wordblocker.contentscan", qos: .utility)
    private var contentScanInFlight = false            // main thread only
    private var lastContentScanURL = ""                // main thread only
    private var lastContentScanTime: Date = .distantPast

    /// Reads the visible text of the focused page and closes the tab if it reads as adult content.
    /// Runs on every new page and then every few seconds, on its own queue, with a strict time budget.
    private func scheduleContentScan(_ found: [ScanHit], pid: pid_t, bundleId: String) {
        guard isMonitoring, WordStore.shared.isEnabled, !contentScanInFlight, !isLeaving,
              let hit = found.first(where: { $0.isFocused && !$0.url.isEmpty }),
              AdultSiteMatcher.host(from: hit.url) != nil,                  // real web pages only
              !TrustedSites.skipsPageTextScan(urlOrHost: hit.url) else { return }   // never judge YouTube, Wikipedia, shops, news, or social feeds by their text

        let now = Date()
        guard hit.url != lastContentScanURL || now.timeIntervalSince(lastContentScanTime) > 4 else { return }
        contentScanInFlight = true
        lastContentScanURL = hit.url
        lastContentScanTime = now

        contentQueue.async { [weak self] in
            guard let self = self else { return }
            let text = self.collectPageText(window: hit.window, title: hit.title)
            let flagged = AdultContentScorer.isAdultContent(text)
            let analysis = flagged ? AdultContentScorer.analyse(text) : nil

            DispatchQueue.main.async {
                self.contentScanInFlight = false
                guard flagged,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let analysis = analysis {
                    BlockLog.record(BlockEvent.pageText(score: analysis.score, distinct: analysis.distinct, terms: analysis.terms,
                                                        page: BlockLog.describePage(hit.url), app: bundleId))
                }
                self.closeFlaggedPage(hit, pid: pid, bundleId: bundleId)
            }
        }
    }

    /// Closes the tab only if the window is still showing the page that was scanned.
    private func closeFlaggedPage(_ hit: ScanHit, pid: pid_t, bundleId: String) {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let current = self.extractURL(from: hit.window, appRef: AXUIElementCreateApplication(pid))
            DispatchQueue.main.async {
                guard current == hit.url else { return }   // navigated away while it was being scanned
                self.showAdultNote()
                self.closeFrontTab(hit, bundleId: bundleId)
            }
        }
    }

    /// (contentQueue) Visible text of a page: its title plus static text, headings, link text, button labels
    /// and image descriptions from the accessibility tree, within a node and time budget.
    private func collectPageText(window: AXUIElement, title: String?) -> String {
        var text = title ?? ""
        guard let webArea = findWebArea(in: window, depth: 0) else { return text }

        let deadline = Date().addingTimeInterval(0.35)
        var pending: [AXUIElement] = [webArea]
        var next = 0
        var visited = 0

        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }

        while next < pending.count, visited < 800, text.count < 12_000, Date() < deadline {
            let element = pending[next]
            next += 1
            visited += 1

            switch string(element, kAXRoleAttribute as String) ?? "" {
            case "AXStaticText":
                if let value = string(element, kAXValueAttribute as String) { text += " " + value }
            case "AXHeading", "AXLink", "AXButton", "AXImage":
                if let value = string(element, kAXTitleAttribute as String) { text += " " + value }
                if let value = string(element, kAXDescriptionAttribute as String) { text += " " + value }
            default:
                break
            }

            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                pending.append(contentsOf: children)
            }
        }
        return text
    }

    private func findWebArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 14 { return nil }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        if (roleValue as? String) == "AXWebArea" { return element }

        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = findWebArea(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// Closes the active tab of whichever monitored browser is in front. Used by the screen image scanner,
    /// which knows something explicit is showing but not which address it came from.
    public func closeFrontmostBrowserTab() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              BrowserLockdown.isMonitored(bundleId) else { return }
        let pid = app.processIdentifier
        scanQueue.async { [weak self] in
            guard let self = self, let (window, _) = self.browserWindows(pid: pid).first else { return }
            DispatchQueue.main.async {
                self.closeFrontTab(ScanHit(window: window, isFocused: true, url: "", title: nil), bundleId: bundleId)
            }
        }
    }

    /// Closes the browser's active tab directly (Cmd+W) when it can't be matched by address.
    private func closeFrontTab(_ hit: ScanHit, bundleId: String) {
        guard !isLeaving else { return }
        isLeaving = true
        AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(hit.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        activateBrowser(bundleId: bundleId)
        waitForFrontmost(bundleId: bundleId, attempts: 20) { [weak self] in
            ActionDispatcher.shared.closeCurrentTab(delay: 0.05) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.finishLeaving() }
            }
        }
    }

    /// Displays an interactive access gate dialog. The user cannot enter the website unless they choose to allow it.
    private func showAccessGatePrompt(note: String?, target: BlockTarget) {
        guard !isGatePromptActive else { return }
        isGatePromptActive = true
        gatePromptShownAt = Date()

        let domain = target.domain
        let noteText = note ?? "Access to \(domain) is blocked. Stay focused on your goals!"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            InterventionModalController.shared.showBlockedWebsite(
                domain: domain,
                note: noteText,
                onLeave: { [weak self] in
                    guard let self = self else { return }
                    // leaveTab sets isLeaving in the same main-thread turn, so no scan can sneak in.
                    self.isGatePromptActive = false
                    self.leaveTab(target)
                },
                onAllow: { [weak self] minutes in
                    // The gate flag stays on until the math challenge is answered (see requestAllowance).
                    self?.requestAllowance(domain: domain, minutes: minutes, target: target)
                },
                onAbandoned: { [weak self] in
                    // Another alert took over the panel before an answer: re-arm so the site gets re-checked.
                    // The math challenge is not an "abandon": it keeps the gate armed until it finishes.
                    guard MathChallengeController.shared.isActive == false else { return }
                    self?.isGatePromptActive = false
                    self?.lastBlockedDomain = nil
                }
            )
        }

        // Auto-close: the page goes away right now, so the pop-up can't just be ignored.
        // "Allow" still works, and after the math challenge you reopen the site.
        if WordStore.shared.closeBlockedTabs {
            leaveTab(target)
        }
    }

    /// Social-media unlock: the allowance is only granted after a run of math problems. The number of
    /// problems grows with each unlock already granted today (5, 7, then 10). Cancelling closes the tab.
    private func requestAllowance(domain: String, minutes: Int, target: BlockTarget) {
        isGatePromptActive = true
        gatePromptShownAt = Date()

        let count = MathChallenge.problemCount(forUnlockNumber: WordStore.shared.unlocksToday())
        MathChallengeController.shared.present(
            title: "Unlock \(domain)",
            reason: "Solve \(count) problems in a row to allow \(domain) for \(minutes) minutes. "
                + "It will be closed again when the time is up.",
            problemCount: count,
            coolOff: MathChallenge.siteUnlockCoolOff(waitEnabled: WordStore.shared.requireUnlockWait)
        ) { [weak self] passed in
            guard let self = self else { return }
            self.isGatePromptActive = false
            self.lastBlockedDomain = nil
            if passed {
                WordStore.shared.recordUnlock()
                WordStore.shared.allowWebsiteTemporarily(domain, minutes: minutes)
                self.scheduleAllowanceTimer(domain: domain, minutes: minutes,
                                            targetBundleId: target.bundleId, fallbackTitle: target.title)
                self.activateBrowser(bundleId: target.bundleId)
            } else {
                self.leaveTab(target)
            }
        }
    }

    // MARK: - Leave Tab (closes target tab regardless of active/background state)

    /// Closes the blocked tab(s) immediately regardless of whether the tab is currently active/selected,
    /// in the background, in another window, or if the user switched to another tab.
    private func leaveTab(_ target: BlockTarget) {
        guard !isLeaving else { return }
        isLeaving = true

        closeAllTabs(matching: target.domain, preferredBundleId: target.bundleId, fallbackTitle: target.title) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.finishLeaving()
            }
        }
    }

    private func finishLeaving() {
        isLeaving = false
        lastBlockedDomain = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.inspectActiveBrowser()
        }
    }

    /// Closes all tabs matching `domain` across browsers (Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi, Firefox, etc.)
    /// regardless of whether the tab is currently active, in the background, or in another window.
    ///
    /// Layer 1: Direct AppleScript tab close by URL (closes foreground & background tabs without stealing focus).
    /// Layer 2: Accessibility tab-strip search — presses the tab's own close button (works on background tabs too),
    ///          or selects the matching tab, verifies its URL, and sends Cmd+W.
    public func closeAllTabs(
        matching domain: String,
        preferredBundleId: String? = nil,
        fallbackTitle: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        let cleanDomain = WordStore.shared.normalizeWebsiteInput(domain).lowercased()
        guard !cleanDomain.isEmpty else {
            completion?()
            return
        }

        // 1. Target the preferred browser first, then check any other running supported browser
        var targetApps: [NSRunningApplication] = []
        if let preferredId = preferredBundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: preferredId).first {
            targetApps.append(app)
        }
        // Includes profile / web-app variants (e.g. Orion profile apps), not just the stock bundle ids.
        for app in NSWorkspace.shared.runningApplications
        where BrowserLockdown.isMonitored(app.bundleIdentifier)
            && app.bundleIdentifier != preferredBundleId
            && !targetApps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            targetApps.append(app)
        }

        // 2. Perform tab closure on background queue so the UI never stalls
        scanQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?() }
                return
            }

            var anyNeedsCmdW: (app: NSRunningApplication, window: AXUIElement)?

            for app in targetApps {
                let bundleId = app.bundleIdentifier ?? ""
                var closedByScript = 0

                // Layer 1: AppleScript-scriptable browsers
                if let appName = app.localizedName, !appName.isEmpty,
                   (bundleId.contains("Chrome") || bundleId.contains("Safari") || bundleId.contains("brave")
                    || bundleId.contains("edgemac") || bundleId.contains("thebrowser")
                    || bundleId.contains("Opera") || bundleId.contains("Vivaldi")) {
                    let scriptSource = """
                    set closedCount to 0
                    if application "\(appName)" is running then
                        tell application "\(appName)"
                            repeat with w in windows
                                repeat with i from (count of tabs of w) to 1 by -1
                                    try
                                        set t to tab i of w
                                        if (URL of t) contains "\(cleanDomain)" then
                                            close t
                                            set closedCount to closedCount + 1
                                        end if
                                    end try
                                end repeat
                            end repeat
                        end tell
                    end if
                    return closedCount
                    """
                    var errorInfo: NSDictionary?
                    if let appleScript = NSAppleScript(source: scriptSource) {
                        let result = appleScript.executeAndReturnError(&errorInfo)
                        if errorInfo == nil {
                            closedByScript = Int(result.int32Value)
                        }
                    }
                }

                if closedByScript > 0 {
                    continue
                }

                // Layer 2: Accessibility fallback (works without Automation permission and on Firefox/all browsers)
                self.enableAccessibilityIfNeeded(pid: app.processIdentifier)
                let appRef = AXUIElementCreateApplication(app.processIdentifier)
                for (window, _) in self.browserWindows(pid: app.processIdentifier) {
                    // 2a. Try finding the tab in the tab bar (even if it's a background tab!)
                    if let tab = self.findTab(titled: fallbackTitle, domain: cleanDomain, in: window, depth: 0) {
                        // If the tab exposes its own 'x' close button, press it directly — closes background tabs in place!
                        if let closeBtn = self.findCloseButton(in: tab, depth: 0),
                           AXUIElementPerformAction(closeBtn, kAXPressAction as CFString) == .success {
                            continue
                        }
                        // Otherwise select the tab so its URL becomes active, then verify and Cmd+W
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(tab, kAXPressAction as CFString)
                        usleep(180_000)
                    }

                    // 2b. If the window's active tab is showing the blocked domain, mark for Cmd+W
                    if let url = self.extractURL(from: window, appRef: appRef),
                       self.shouldCloseActiveTab(url: url, cleanDomain: cleanDomain) {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        anyNeedsCmdW = (app, window)
                        break
                    }
                }
            }

            DispatchQueue.main.async {
                guard let target = anyNeedsCmdW, let bundleId = target.app.bundleIdentifier else {
                    completion?()
                    return
                }
                self.activateBrowser(bundleId: bundleId)
                self.waitForFrontmost(bundleId: bundleId, attempts: 20) {
                    ActionDispatcher.shared.closeCurrentTab(delay: 0.05) {
                        completion?()
                    }
                }
            }
        }
    }

    /// (scanQueue) Safety check before sending Cmd+W: the active tab must really be the blocked page,
    /// either one from the user's list or a built-in adult site.
    private func shouldCloseActiveTab(url: String, cleanDomain: String) -> Bool {
        let lowerURL = url.lowercased()
        if let match = WordStore.shared.matchBlockedWebsite(urlOrHost: url),
           match.matchedDomain.lowercased() == cleanDomain || lowerURL.contains(cleanDomain) {
            return true
        }
        return (AdultSiteMatcher.isAdult(urlOrHost: url) || AdultSiteMatcher.isAdultSearch(urlOrHost: url))
            && lowerURL.contains(cleanDomain)
    }

    /// (scanQueue) Finds a tab button (AXRadioButton / AXTab in the tab strip) matching the recorded title or domain.
    private func findTab(titled title: String?, domain: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 8 { return nil }
        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String ?? ""
        if role == "AXWebArea" { return nil } // never descend into page content

        if role == "AXRadioButton" || role == "AXTab" {
            var titleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleVal)
            let tabTitle = titleVal as? String ?? ""
            if let title = title, !title.isEmpty, tabTitle == title {
                return element
            }
            let baseDomain = domain.components(separatedBy: "/").first?.lowercased() ?? domain.lowercased()
            if !baseDomain.isEmpty && tabTitle.lowercased().contains(baseDomain) {
                return element
            }
        }

        var childrenVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children {
                if let found = findTab(titled: title, domain: domain, in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// (scanQueue) Finds the close ('x') button inside a tab element so background tabs can be closed directly.
    private func findCloseButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 4 { return nil }
        var childrenVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else {
            return nil
        }
        for child in children {
            var roleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleVal)
            if (roleVal as? String) == "AXButton" {
                var subroleVal: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleVal)
                if (subroleVal as? String) == (kAXCloseButtonSubrole as String) {
                    return child
                }
                var descVal: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descVal)
                var titleVal: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleVal)
                let label = ((descVal as? String) ?? (titleVal as? String) ?? "").lowercased()
                if label.contains("close") {
                    return child
                }
            }
            if let nested = findCloseButton(in: child, depth: depth + 1) {
                return nested
            }
        }
        return nil
    }

    private func windowTitle(_ window: AXUIElement) -> String? {
        var titleVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleVal) == .success else {
            return nil
        }
        return titleVal as? String
    }

    // MARK: - Temporary Allowance Timers

    /// Schedules an automated timer that automatically closes the tab(s) when the temporary allowance ends,
    /// regardless of where the user is in the browser or which app is frontmost.
    public func scheduleAllowanceTimer(
        domain: String,
        minutes: Int,
        targetBundleId: String?,
        fallbackTitle: String? = nil
    ) {
        let cleanDomain = WordStore.shared.normalizeWebsiteInput(domain).lowercased()
        allowanceTimers[cleanDomain]?.invalidate()

        let interval = Double(minutes * 60)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("[BrowserMonitor] Allowance expired for \(cleanDomain). Auto-closing tabs...")
            WordStore.shared.revokeTemporaryAllowance(cleanDomain)
            self.allowanceTimers.removeValue(forKey: cleanDomain)

            // Auto-close tabs for this domain regardless of where you are in the browser!
            self.closeAllTabs(matching: cleanDomain, preferredBundleId: targetBundleId, fallbackTitle: fallbackTitle) { [weak self] in
                self?.lastBlockedDomain = nil
                self?.inspectActiveBrowser()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        allowanceTimers[cleanDomain] = timer
    }

    public func clearAllAllowanceTimers() {
        allowanceTimers.values.forEach { $0.invalidate() }
        allowanceTimers.removeAll()
    }

    private func waitForFrontmost(bundleId: String, attempts: Int, then action: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId || attempts <= 0 {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFrontmost(bundleId: bundleId, attempts: attempts - 1, then: action)
        }
    }

    private func activateBrowser(bundleId: String) {
        if let browser = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            browser.activate()
        }
    }

    private func handleBlockedWebsiteDetected(note: String?, target: BlockTarget) {
        let domain = target.domain
        let noteText = note ?? "Access to \(domain) is restricted. Stay focused on your goals!"

        if WordStore.shared.showWebsiteNotes {
            DispatchQueue.main.async { [weak self] in
                InterventionModalController.shared.showBlockedWebsite(
                    domain: domain,
                    note: noteText,
                    onLeave: { [weak self] in
                        self?.leaveTab(target)
                    },
                    onAllow: { [weak self] minutes in
                        self?.requestAllowance(domain: domain, minutes: minutes, target: target)
                    }
                )
            }
        }

        if WordStore.shared.closeBlockedTabs {
            leaveTab(target)
        }
    }

    /// Chromium and Firefox only build their accessibility tree when asked; without this the URL
    /// is often unreadable (Firefox especially).
    private func enableAccessibilityIfNeeded(pid: pid_t) {
        guard !axEnabledPids.contains(pid) else { return }
        axEnabledPids.insert(pid)
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The browser's focused window first, followed by its other standard, on-screen windows.
    private func browserWindows(pid: pid_t) -> [(AXUIElement, Bool)] {
        let appRef = AXUIElementCreateApplication(pid)
        var result: [(AXUIElement, Bool)] = []

        var focusedVal: CFTypeRef?
        var focused: AXUIElement?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedVal) == .success
            || AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &focusedVal) == .success,
           let f = focusedVal {
            focused = (f as! AXUIElement)
            result.append((focused!, true))
        }

        var windowsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsVal) == .success,
           let windows = windowsVal as? [AXUIElement] {
            for w in windows.prefix(8) {
                if let f = focused, CFEqual(f, w) { continue }
                var minVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minVal) == .success,
                   (minVal as? Bool) == true { continue }
                var subVal: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subVal)
                if let sub = subVal as? String, sub != (kAXStandardWindowSubrole as String) { continue }
                result.append((w, false))
            }
        }
        return result
    }

    /// Public entry kept for callers/tests: URL of the focused browser window.
    public func extractActiveURL(for pid: pid_t, bundleId: String) -> String? {
        guard let (win, _) = browserWindows(pid: pid).first else { return nil }
        return extractURL(from: win, appRef: AXUIElementCreateApplication(pid))
    }

    /// Reads the loaded page's URL. Prefers what the page actually loaded (AXDocument / web area AXURL)
    /// over the address bar, because the address bar may hold text the user is still typing.
    private func extractURL(from win: AXUIElement, appRef: AXUIElement) -> String? {
        // Strategy 1: window document attribute (Chromium browsers)
        var docVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docVal) == .success,
           let docStr = docVal as? String, !docStr.isEmpty {
            return docStr
        }

        // Strategy 2: window AXURL
        var urlVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXURL" as CFString, &urlVal) == .success,
           let urlStr = (urlVal as? URL)?.absoluteString ?? (urlVal as? String), !urlStr.isEmpty {
            return urlStr
        }

        // Strategy 3: the page's web area carries the real loaded URL (Safari, Firefox, others)
        if let webURL = findWebAreaURL(in: win, depth: 0) {
            return webURL
        }

        // Strategy 4: address bar, but only when the user isn't currently editing it
        var focusedUIVal: CFTypeRef?
        var focusedUI: AXUIElement?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedUIVal) == .success,
           let f = focusedUIVal {
            focusedUI = (f as! AXUIElement)
        }
        return findAddressBar(in: win, depth: 0, skipping: focusedUI)
    }

    private func findWebAreaURL(in element: AXUIElement, depth: Int) -> String? {
        if depth > 14 { return nil }
        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        if (roleVal as? String) == "AXWebArea" {
            var urlVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlVal) == .success,
               let urlStr = (urlVal as? URL)?.absoluteString ?? (urlVal as? String), !urlStr.isEmpty {
                return urlStr
            }
            return nil // don't descend into page content
        }
        var childrenVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children {
                if let found = findWebAreaURL(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func findAddressBar(in element: AXUIElement, depth: Int, skipping editing: AXUIElement?) -> String? {
        if depth > 12 { return nil }
        if let editing = editing, CFEqual(editing, element) { return nil }
        var roleCheck: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCheck)
        if (roleCheck as? String) == "AXWebArea" { return nil } // never read text fields inside pages

        // Check Safari identifier
        var identVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identVal)
        if let ident = identVal as? String, ident == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val) == .success,
               let str = val as? String, !str.isEmpty {
                return str
            }
        }

        // Check text field / combo box description or value
        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String ?? ""

        if role == "AXTextField" || role == "AXComboBox" {
            var descVal: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descVal)
            let desc = (descVal as? String ?? "").lowercased()

            if desc.contains("address") || desc.contains("search") || desc.contains("url") {
                var val: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val) == .success,
                   let str = val as? String, isLikelyURL(str) {
                    return str
                }
            }
        }

        // Search children
        var childrenVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children {
                if let found = findAddressBar(in: child, depth: depth + 1, skipping: editing) {
                    return found
                }
            }
        }

        return nil
    }

    private func isLikelyURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(" ") { return false }
        return trimmed.contains(".") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }
}
