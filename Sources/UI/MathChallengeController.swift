import Cocoa

/// Centered panel that makes you solve a run of math problems before an action is allowed.
/// Flow: mandatory cool-off countdown -> N problems in a row (any wrong answer starts over with new
/// problems) -> `completion(true)`. Cancel / Escape -> `completion(false)`.
public final class MathChallengeController: NSWindowController {
    public static let shared = MathChallengeController()

    private var panel: CustomInterventionPanel!
    private var badgeLabel: NSTextField!
    private var reasonLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var problemLabel: NSTextField!
    private var answerField: NSTextField!
    private var feedbackLabel: NSTextField!
    private var cancelButton: NSButton!

    private var session: MathChallengeSession?
    private var completion: ((Bool) -> Void)?
    private var timer: Timer?
    /// Monotonic deadline (system uptime), so changing the clock can't skip the cool-off.
    private var coolOffDeadline: TimeInterval = 0

    public private(set) var isActive = false

    private convenience init() {
        let panel = CustomInterventionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear

        self.init(window: panel)
        self.panel = panel
        setupUI()
    }

    private func setupUI() {
        guard let content = panel.contentView else { return }

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        effect.layer?.borderWidth = 1.0
        content.addSubview(effect)

        badgeLabel = NSTextField(labelWithString: "WORD BLOCKER")
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.frame = NSRect(x: 18, y: 250, width: 404, height: 16)
        effect.addSubview(badgeLabel)

        reasonLabel = NSTextField(wrappingLabelWithString: "")
        reasonLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        reasonLabel.textColor = .labelColor
        reasonLabel.frame = NSRect(x: 18, y: 200, width: 404, height: 46)
        effect.addSubview(reasonLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 18, y: 174, width: 404, height: 18)
        effect.addSubview(statusLabel)

        problemLabel = NSTextField(labelWithString: "")
        problemLabel.font = .monospacedSystemFont(ofSize: 30, weight: .semibold)
        problemLabel.textColor = .labelColor
        problemLabel.alignment = .center
        problemLabel.frame = NSRect(x: 18, y: 120, width: 404, height: 44)
        effect.addSubview(problemLabel)

        answerField = NSTextField(frame: NSRect(x: 140, y: 78, width: 160, height: 30))
        answerField.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        answerField.alignment = .center
        answerField.placeholderString = "Answer"
        answerField.target = self
        answerField.action = #selector(answerSubmitted)
        effect.addSubview(answerField)

        feedbackLabel = NSTextField(labelWithString: "")
        feedbackLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        feedbackLabel.alignment = .center
        feedbackLabel.frame = NSRect(x: 18, y: 52, width: 404, height: 16)
        effect.addSubview(feedbackLabel)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 18, y: 12, width: 90, height: 28)
        effect.addSubview(cancelButton)

        panel.onCancelOperation = { [weak self] in self?.cancelClicked() }
    }

    // MARK: - API

    /// Shows the challenge. `completion(true)` only after every problem is solved; `completion(false)` on
    /// cancel. If a challenge is already on screen, the new request is refused (`completion(false)`).
    public func present(
        title: String,
        reason: String,
        problemCount: Int,
        coolOff: TimeInterval = MathChallenge.coolOffSeconds,
        completion: @escaping (Bool) -> Void
    ) {
        guard !isActive else {
            panel.makeKeyAndOrderFront(nil)
            completion(false)
            return
        }
        isActive = true
        self.completion = completion
        session = MathChallengeSession(count: problemCount)

        badgeLabel.stringValue = "WORD BLOCKER  ·  \(title.uppercased())"
        reasonLabel.stringValue = reason
        feedbackLabel.stringValue = ""
        answerField.stringValue = ""

        if coolOff > 0 {
            coolOffDeadline = ProcessInfo.processInfo.systemUptime + coolOff
            showCoolOff(remaining: coolOff)
        } else {
            coolOffDeadline = 0
            showProblem()
        }

        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        center()
        if WordStore.shared.playAlertSound { NSSound.beep() }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Flow

    private func center() {
        guard let screen = NSScreen.main else { panel.center(); return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.midY - panel.frame.height / 2 + 60))
    }

    private var isCoolingOff: Bool { coolOffDeadline > ProcessInfo.processInfo.systemUptime }

    private func tick() {
        guard isActive else { return }
        if coolOffDeadline > 0 {
            let remaining = coolOffDeadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                showCoolOff(remaining: remaining)
            } else {
                coolOffDeadline = 0
                showProblem()
            }
        }
    }

    private func showCoolOff(remaining: TimeInterval) {
        statusLabel.stringValue = "Take a breath. Problems start in \(Int(remaining.rounded(.up)))s…"
        problemLabel.stringValue = "…"
        answerField.isHidden = true
        answerField.isEnabled = false
    }

    private func showProblem() {
        guard let session = session, let problem = session.current else { return }
        statusLabel.stringValue = "Problem \(session.index + 1) of \(session.requiredCount)   ·   one wrong answer starts over"
        problemLabel.stringValue = problem.prompt
        answerField.isHidden = false
        answerField.isEnabled = true
        answerField.stringValue = ""
        panel.makeFirstResponder(answerField)
    }

    @objc private func answerSubmitted() {
        guard isActive, !isCoolingOff, let session = session else { return }
        switch session.submit(answerField.stringValue) {
        case .invalid:
            feedbackLabel.textColor = .secondaryLabelColor
            feedbackLabel.stringValue = "Enter a whole number."
        case .correct(let finished):
            if finished {
                finish(passed: true)
            } else {
                feedbackLabel.textColor = .systemGreen
                feedbackLabel.stringValue = "Correct."
                showProblem()
            }
        case .wrong:
            feedbackLabel.textColor = .systemRed
            feedbackLabel.stringValue = "Wrong. Starting over with new problems."
            showProblem()
        }
    }

    @objc private func cancelClicked() {
        finish(passed: false)
    }

    private func finish(passed: Bool) {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        isActive = false
        session = nil
        let done = completion
        completion = nil
        panel.orderOut(nil)
        done?(passed)
    }
}
