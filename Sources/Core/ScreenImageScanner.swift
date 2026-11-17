import Cocoa
import CoreML
import ScreenCaptureKit
import Vision

/// Looks at the screen for explicit images, in any app, using an on-device image model.
///
/// Everything stays on the Mac: no screenshot is saved or sent anywhere. It needs two things the user
/// provides: Screen Recording permission, and the converted model (`scripts/convert_nsfw_model.py`, which
/// saves `NSFW.mlpackage` into `~/Library/Application Support/WordBlocker/`).
///
/// It is built to be light on battery (see `ImageScanLogic`): it captures a small image, only runs the
/// model when the screen has changed, backs off when the screen is static, slows down in Low Power Mode,
/// and pauses when the display is asleep or the session is locked.
///
/// What it cannot do: react before the image has been on screen for a moment (capture and scan take up to
/// a second or two), or promise accuracy; a model makes mistakes both ways.
public final class ScreenImageScanner {
    public static let shared = ScreenImageScanner()

    public enum Status: Equatable {
        case stopped, needsPermission, needsModel, loadingModel, watching, paused
    }

    public var onChange: (() -> Void)?

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    public var statusText: String {
        switch status {
        case .stopped: return "Image scanner: off"
        case .needsPermission: return "Image scanner: needs Screen Recording (click to open)"
        case .needsModel: return "Image scanner: model not installed"
        case .loadingModel: return "Image scanner: preparing model…"
        case .watching: return "Image scanner: watching"
        case .paused: return "Image scanner: paused"
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private var currentStatus: Status = .stopped
    private var runToken = 0
    private var running = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var askedForPermission = false

    // Touched only by the scan loop, which never overlaps itself.
    private var model: VNCoreMLModel?
    private var modelStamp: Date?
    private var lastThumbnails: [UInt32: [UInt8]] = [:]
    private var unchangedScans = 0
    private var suspectPending = false
    private var frontIsSearchResults = false     // set each scan: a search engine's page is in front
    private var lastIgnoredLog = Date.distantPast
    private var lastTraceLog = Date.distantPast

    private let queue = DispatchQueue(label: "com.wordblocker.imagescan", qos: .utility)
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Start / stop

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        runToken += 1
        let token = runToken
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }
        watch(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.setFlag(\.screensAsleep, true) }
        watch(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.setFlag(\.screensAsleep, false) }
        watch(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.setFlag(\.sessionInactive, true) }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.setFlag(\.sessionInactive, false) }

        schedule(after: 2, token: token)
    }

    public func stop() {
        lock.lock()
        running = false
        runToken += 1
        lock.unlock()

        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        setStatus(.stopped)
    }

    private func setFlag(_ keyPath: ReferenceWritableKeyPath<ScreenImageScanner, Bool>, _ value: Bool) {
        lock.lock()
        self[keyPath: keyPath] = value
        lock.unlock()
    }

    private func setStatus(_ new: Status) {
        lock.lock()
        let changed = currentStatus != new
        currentStatus = new
        lock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    }

    // MARK: - Loop

    private func schedule(after delay: Double, token: Int) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            Task {
                await self.scanOnce()
                let stillCurrent = self.lock.withLock { self.running && token == self.runToken }
                guard stillCurrent else { return }
                let interval = ImageScanLogic.interval(
                    unchangedScans: self.unchangedScans,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
                )
                self.schedule(after: self.suspectPending ? 0.5 : interval, token: token)
            }
        }
    }

    private func scanOnce() async {
        guard await isReadyToScan() else { return }

        // One look at what is on screen per scan, shared by every display.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return
        }

        for display in content.displays {
            guard let image = await capture(display, windows: content.windows) else { continue }

            let thumbnail = makeThumbnail(of: image)
            let id = display.displayID
            var changed = true
            if let last = lastThumbnails[id] {
                changed = ImageScanLogic.difference(last, thumbnail) >= ImageScanLogic.changeThreshold
            }
            lastThumbnails[id] = thumbnail
            unchangedScans = changed ? 0 : unchangedScans + 1

            // The model only runs on a changed screen, or to re-check something suspicious.
            guard changed || suspectPending else { continue }

            let scores = classify(image)
            let strict = frontIsSearchResults

            // Tuning aid, off unless `defaults write com.wordblocker.app WordBlocker.ScanTrace -bool true`:
            // the scores of a scan, at most every 4 s, so the bar can be set from what the model really says.
            if UserDefaults.standard.bool(forKey: "WordBlocker.ScanTrace"), Date().timeIntervalSince(lastTraceLog) > 4 {
                lastTraceLog = Date()
                await logScan("trace", scores: scores, strict: strict, trace: true)
            }

            // A coarse look that the finer tiles inside it do not back up is the model misreading a busy screen.
            let supported = ImageScanLogic.supportedScores(scores, tiles: ImageScanLogic.tiles(width: image.width, height: image.height))
            let verdict = ImageScanLogic.verdict(scores: supported, previouslySuspect: suspectPending, onSearchResults: strict)
            switch verdict {
            case .clear:
                // A middling score is not acted on, but it is logged (at most every 20 s) so the log shows what
                // the model made of a picture it missed, and what the stricter rules held back.
                if (scores.max() ?? 0) >= ImageScanLogic.noteScore, Date().timeIntervalSince(lastIgnoredLog) > 20 {
                    lastIgnoredLog = Date()
                    let heldBack = supported != scores
                    await recordImageEvent(outcome: .nearMiss, nearMiss: heldBack ? .heldBack : .belowBar,
                                           scores: scores, decided: supported, strict: strict,
                                           bodyParts: await findBodyParts(image, scores: heldBack ? scores : supported))
                }
                suspectPending = false
            case .suspect:
                if !suspectPending {
                    await recordImageEvent(outcome: .nearMiss, nearMiss: .recheck, scores: scores, decided: supported, strict: strict)
                }
                suspectPending = true
            case .explicit:
                // What was in front, before closing it changes that.
                let context = await frontContext()
                suspectPending = false
                lastThumbnails.removeAll()
                // Closing comes first; working out and writing down why takes a moment longer.
                await respond()
                await recordImageEvent(outcome: .blocked, scores: scores, decided: supported, strict: strict,
                                       context: context, looksLike: describePicture(image, scores: supported),
                                       bodyParts: await findBodyParts(image, scores: supported))
                return
            }
        }
    }

    /// Checks everything a scan needs, updating the status the menu shows. Returns false to skip this scan.
    private func isReadyToScan() async -> Bool {
        guard WordStore.shared.isEnabled else { setStatus(.paused); return false }

        if !CGPreflightScreenCaptureAccess() {
            setStatus(.needsPermission)
            if !askedForPermission {
                askedForPermission = true
                _ = CGRequestScreenCaptureAccess()   // shows the system prompt once per launch
            }
            return false
        }

        await loadModelIfNeeded()
        guard model != nil else { return false }

        let blocked = lock.withLock { screensAsleep || sessionInactive }
        if blocked { setStatus(.paused); return false }

        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        if let id = frontmost, ImageScanLogic.ignoredBundleIdentifiers.contains(id) || id == Bundle.main.bundleIdentifier {
            setStatus(.paused)
            return false
        }

        // Everyday sites (YouTube, Wikipedia, shops, news…) are never judged by the image model: it
        // misreads video frames and product photos, and the user only wants adult sites blocked.
        frontIsSearchResults = false
        if let id = frontmost, BrowserLockdown.isMonitored(id) {
            let page = await MainActor.run { BrowserMonitor.shared.frontPageURL }
            if let page = page, TrustedSites.isTrusted(urlOrHost: page) {
                suspectPending = false
                setStatus(.paused)
                return false
            }
            // Search results are a mosaic of thumbnails: the model gets a stricter bar there.
            frontIsSearchResults = page.map { ImageScanLogic.isSearchResultsPage($0) } ?? false
        }

        setStatus(.watching)
        return true
    }

    // MARK: - Model

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordBlocker", isDirectory: true)
    }

    /// Loads `NSFW.mlmodelc`, compiling it from `NSFW.mlpackage` first when needed (or when the package is
    /// newer than the compiled copy).
    private func loadModelIfNeeded() async {
        let package = supportDirectory.appendingPathComponent("NSFW.mlpackage")
        let compiled = supportDirectory.appendingPathComponent("NSFW.mlmodelc")
        let manager = FileManager.default

        func modified(_ url: URL) -> Date? {
            (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        let packageDate = modified(package)
        let compiledDate = modified(compiled)

        if model != nil, modelStamp == (compiledDate ?? packageDate) { return }

        do {
            if let packageDate = packageDate, compiledDate == nil || compiledDate! < packageDate {
                setStatus(.loadingModel)
                let temporary = try await MLModel.compileModel(at: package)
                try? manager.removeItem(at: compiled)
                try manager.moveItem(at: temporary, to: compiled)
            }
            guard manager.fileExists(atPath: compiled.path) else {
                model = nil
                setStatus(.needsModel)
                return
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine   // the Neural Engine is the efficient way to run this
            model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
            modelStamp = modified(compiled)
        } catch {
            print("[ScreenImageScanner] Could not load the model: \(error)")
            model = nil
            setStatus(.needsModel)
        }
    }

    // MARK: - Capture

    /// A small screenshot of one display (long side about 640 px), without Word Blocker's own windows so
    /// its cover never confuses the scan.
    private func capture(_ display: SCDisplay, windows: [SCWindow]) async -> CGImage? {
        do {
            let own = windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: own)

            let configuration = SCStreamConfiguration()
            let scale = ImageScanLogic.captureLongSide / Double(max(display.width, display.height))
            configuration.width = max(1, Int(Double(display.width) * scale))
            configuration.height = max(1, Int(Double(display.height) * scale))
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    private func makeThumbnail(of image: CGImage) -> [UInt8] {
        let width = ImageScanLogic.thumbnailWidth
        let height = ImageScanLogic.thumbnailHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    // MARK: - Classification

    /// The model's "explicit" probability for the whole screen and for each quarter of it.
    private func classify(_ image: CGImage) -> [Double] {
        guard let model = model else { return [] }
        var scores: [Double] = []
        for tile in ImageScanLogic.tiles(width: image.width, height: image.height) {
            guard let crop = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else {
                continue
            }
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) } catch { continue }

            let results = (request.results as? [VNClassificationObservation]) ?? []
            let explicit = results.first { $0.identifier.lowercased().contains("nsfw") }
            scores.append(Double(explicit?.confidence ?? 0))
        }
        return scores
    }

    // MARK: - Log

    /// The app and page in front right now.
    private func frontContext() async -> (page: String?, app: String) {
        await MainActor.run {
            (BrowserMonitor.shared.frontPageURL, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        }
    }

    /// One scan's scores for the tuning trace (`scan-trace.log`): the highest score and its tile, every score
    /// (whole screen, then the 2x2 grid, then the 3x3 grid, each row by row), the app and page in front, and
    /// whether the strict search-page bars applied.
    private func logScan(_ what: String, scores: [Double], strict: Bool, trace: Bool = false) async {
        let front = await frontContext()
        let list = scores.map { String(format: "%.3f", $0) }.joined(separator: " ")
        let top = scores.max() ?? 0
        let topTile = scores.firstIndex(of: top) ?? 0
        BlockLog.record("image-scanner", "\(what)  top=\(String(format: "%.4f", top)) tile=\(topTile)  scores(whole | 2x2 | 3x3)=[\(list)]  strict=\(strict)  app=\(front.app)  page=\(BlockLog.describePage(front.page))", trace: trace)
    }

    /// Records a block, or a high score that was not acted on, in the block log with its full explanation.
    /// `decided` are the scores the verdict used (a coarse hit the finer tiles did not back up is zeroed there).
    private func recordImageEvent(outcome: BlockEvent.Outcome, nearMiss: ImageScanLogic.NearMiss? = nil,
                                  scores: [Double], decided: [Double], strict: Bool,
                                  context: (page: String?, app: String)? = nil, looksLike: String = "",
                                  bodyParts: [BodyPartLogic.Detection]? = nil) async {
        let front: (page: String?, app: String)
        if let context = context { front = context } else { front = await frontContext() }
        let action: String
        if outcome == .nearMiss {
            action = "Nothing closed"
        } else if BrowserLockdown.isMonitored(front.app) {
            action = "Tab closed"
        } else {
            action = "App hidden"
        }
        BlockLog.record(BlockEvent.image(
            outcome: outcome, nearMiss: nearMiss, scores: scores, decided: decided, strict: strict, looksLike: looksLike,
            bodyParts: bodyParts, action: action, page: front.page.map { BlockLog.describePage($0) }, app: front.app
        ))
    }

    /// The part of the screen that scored highest, cut out of the screenshot.
    private func topTileCrop(_ image: CGImage, scores: [Double]) -> CGImage? {
        guard let top = scores.max(), let index = scores.firstIndex(of: top) else { return nil }
        let tiles = ImageScanLogic.tiles(width: image.width, height: image.height)
        guard index < tiles.count else { return nil }
        let tile = tiles[index]
        return image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height))
    }

    /// What the body-part detector finds in the part of the screen that scored highest: nil when its model is not
    /// installed, an empty list when it looked and found nothing. Like `describePicture` it only runs when
    /// something is logged, and nothing is kept but the labels.
    private func findBodyParts(_ image: CGImage, scores: [Double]) async -> [BodyPartLogic.Detection]? {
        guard BodyPartDetector.shared.isInstalled, let crop = topTileCrop(image, scores: scores) else { return nil }
        return await BodyPartDetector.shared.detect(in: crop)
    }

    /// What a general-purpose picture classifier (Apple's, built into macOS; not the explicit-content model)
    /// makes of the part of the screen that scored highest, as `person 93%, swimwear 41%`. Run only when
    /// something is blocked, so it costs no battery. Labels only: the picture itself is never kept.
    private func describePicture(_ image: CGImage, scores: [Double]) -> String {
        guard let top = scores.max(), let index = scores.firstIndex(of: top) else { return "" }
        let tiles = ImageScanLogic.tiles(width: image.width, height: image.height)
        guard index < tiles.count else { return "" }
        let tile = tiles[index]
        guard let crop = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else { return "" }
        let request = VNClassifyImageRequest()
        do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) } catch { return "" }
        let observations = request.results ?? []
        return ImageScanLogic.describeLabels(observations.map { (name: $0.identifier, confidence: Double($0.confidence)) })
    }

    // MARK: - Response

    /// Covers every screen at once, then deals with what was showing: a browser loses its active tab,
    /// any other app is hidden.
    private func respond() async {
        await MainActor.run {
            ScreenCover.show(message: "Explicit image detected and closed.")

            let front = NSWorkspace.shared.frontmostApplication
            if BrowserLockdown.isMonitored(front?.bundleIdentifier) {
                BrowserMonitor.shared.closeFrontmostBrowserTab()
            } else if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                front?.hide()
            }
        }
    }
}

/// A black full-screen cover shown for a couple of seconds on every display.
enum ScreenCover {
    private static var windows: [NSWindow] = []

    @MainActor
    static func show(message: String) {
        hide()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 22, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            label.sizeToFit()
            label.frame.origin = NSPoint(x: (screen.frame.width - label.frame.width) / 2, y: screen.frame.height / 2)
            window.contentView?.addSubview(label)

            window.orderFrontRegardless()
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { hide() }
    }

    @MainActor
    static func hide() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}
