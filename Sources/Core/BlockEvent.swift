import Foundation

/// One entry of the block log: what was closed (or nearly closed), by which check, and why, in a form the
/// Block Log window can show and `blocks.jsonl` can store. It holds the rule that matched and the numbers
/// behind the decision, never search words, page text or pictures, and addresses without their query string.
public struct BlockEvent: Codable, Equatable {

    public enum Kind: String, Codable, Equatable {
        case image, website
    }

    /// `blocked`: something was closed. `nearMiss`: a high score that was not acted on (kept so a miss, or a
    /// close call, can be explained too).
    public enum Outcome: String, Codable, Equatable {
        case blocked, nearMiss
    }

    public struct Detail: Codable, Equatable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// One stage of the decision: what it looked at, what it found, and what part it played.
    public struct Step: Codable, Equatable {
        public enum Result: String, Codable, Equatable {
            case decided     // this is what caused the block
            case supports    // agrees with it
            case against     // looked and did not agree
            case clear       // looked and nothing triggered
            case context     // information only; it neither decides nor vetoes
            case skipped     // did not run, or was not needed

            public var tag: String {
                switch self {
                case .decided: return "DECIDED"
                case .supports: return "AGREES"
                case .against: return "DOES NOT AGREE"
                case .clear: return "NOT TRIGGERED"
                case .context: return "CONTEXT"
                case .skipped: return "NOT RUN"
                }
            }
        }

        public var title: String
        public var result: Result
        public var detail: String

        public init(_ title: String, _ result: Result, _ detail: String) {
            self.title = title
            self.result = result
            self.detail = detail
        }
    }

    /// How well the block is backed up: a second, independent check agreed, only the main check fired, or there
    /// was no second check to ask.
    public enum Confidence: String, Codable, Equatable {
        case corroborated, modelOnly, notCrossChecked, learned

        public var label: String {
            switch self {
            case .corroborated: return "Second opinion agrees"
            case .modelOnly: return "Image model only"
            case .notCrossChecked: return "No second opinion"
            case .learned: return "Matches your correction"
            }
        }
    }

    public var id: String
    public var date: Date
    public var kind: Kind
    public var outcome: Outcome
    /// Which check produced it: `adult-site`, `adult-search`, `adult-community`, `adult-title`, `page-text`,
    /// `image-scan`, `image-recheck`, `image-near-miss`, `image-held-back`.
    public var check: String
    public var headline: String
    /// The reason, in plain sentences.
    public var why: String
    /// What was done about it: "Tab closed", "App hidden", "Nothing closed".
    public var action: String
    /// The address without scheme or query string, when there was one.
    public var page: String?
    /// The front app's bundle identifier.
    public var app: String?
    public var details: [Detail]
    /// For image events, the model's scores: whole screen, then the 2x2 grid, then the 3x3 grid.
    public var scores: [Double]?
    public var strict: Bool?
    /// The stages of the decision, in the order they ran (nil for entries recorded before steps existed).
    public var steps: [Step]?
    /// A plain summary of what happened and how much to trust it.
    public var assessment: String?
    public var confidence: Confidence?
    /// True when a fingerprint of the flagged area was kept, so marking this entry can teach the scanner.
    public var canLearn: Bool?

    /// The first sentence of the assessment: short enough for the screen cover and the block note.
    public var brief: String? {
        guard let text = assessment, let end = text.range(of: ". ") ?? text.range(of: ".", options: .backwards) else { return assessment }
        return String(text[text.startIndex..<end.upperBound]).trimmingCharacters(in: .whitespaces)
    }

    /// What the website block note says: the short reason, and where the rest is.
    public var noteText: String {
        (brief ?? headline) + " Details: Show Block Log in the menu bar."
    }

    /// What the black cover says for a couple of seconds after an image block.
    public var coverText: String {
        var text = brief ?? headline
        switch confidence {
        case .corroborated?: text += " A second check, the body-part detector, agrees."
        case .modelOnly?: text += " A second check, the body-part detector, found nothing explicit there."
        case .notCrossChecked?: text += " No second check was available."
        case .learned?: break      // the brief already says it matches what you marked
        case nil: break
        }
        return text + "\n\nFull reasons: Show Block Log in the menu bar."
    }

    public init(id: String = UUID().uuidString, date: Date = Date(), kind: Kind, outcome: Outcome = .blocked, check: String,
                headline: String, why: String, action: String, page: String? = nil, app: String? = nil,
                details: [Detail] = [], scores: [Double]? = nil, strict: Bool? = nil,
                steps: [Step]? = nil, assessment: String? = nil, confidence: Confidence? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.outcome = outcome
        self.check = check
        self.headline = headline
        self.why = why
        self.action = action
        self.page = page
        self.app = app
        self.details = details
        self.scores = scores
        self.strict = strict
        self.steps = steps
        self.assessment = assessment
        self.confidence = confidence
    }

    // MARK: - Names

    public static func headline(forCheck check: String) -> String {
        switch check {
        case "adult-site": return "Adult website closed"
        case "adult-search": return "Explicit search closed"
        case "adult-community": return "Adult Reddit community closed"
        case "adult-title": return "Adult page title closed"
        case "page-text": return "Adult page text closed"
        case "image-scan": return "Explicit image closed"
        case "image-recheck": return "Possible image, rechecking"
        case "image-near-miss": return "High score, nothing closed"
        case "image-held-back": return "Score set aside, nothing closed"
        case "image-not-confirmed": return "Flagged, not confirmed: left open"
        case "image-learned-hold": return "Held: looks like something you marked not explicit"
        default: return check
        }
    }

    public static func checkName(_ check: String) -> String {
        switch check {
        case "adult-site": return "Adult website list and rules"
        case "adult-search": return "Explicit search rules"
        case "adult-community": return "Adult Reddit community rules"
        case "adult-title": return "Page title rules"
        case "page-text": return "Page text scan"
        case "image-scan", "image-recheck", "image-near-miss", "image-held-back", "image-not-confirmed", "image-learned-hold": return "Screen image scanner"
        default: return check
        }
    }

    public static func ruleName(_ rule: String) -> String {
        switch rule {
        case "adult-tld": return "Adult domain ending"
        case "known-domain": return "Built-in adult site list"
        case "blocklist": return "Downloaded blocklists"
        case "domain-keyword": return "Keyword in the site name"
        case "domain-word": return "Word in the site name"
        case "search-phrase": return "Explicit phrase list"
        case "search-word": return "Explicit word list"
        case "search-fragment": return "Explicit word-fragment list"
        case "community-name": return "Adult community name"
        case "post-title": return "Explicit post title"
        case "title-keyword": return "Page title keyword"
        default: return rule
        }
    }

    /// A readable app name for a bundle identifier (`com.google.Chrome` becomes `Chrome`).
    public static func appName(_ bundleIdentifier: String?) -> String {
        guard let id = bundleIdentifier, !id.isEmpty, id != "?" else { return "Unknown app" }
        let known: [String: String] = [
            "com.google.Chrome": "Chrome", "com.google.Chrome.canary": "Chrome Canary", "com.apple.Safari": "Safari",
            "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
            "company.thebrowser.Browser": "Arc", "com.operasoftware.Opera": "Opera", "com.vivaldi.Vivaldi": "Vivaldi",
            "com.apple.Safari.SandboxBroker": "Safari", "com.anthropic.claudefordesktop": "Claude",
            "com.apple.finder": "Finder", "com.apple.Preview": "Preview", "com.apple.Photos": "Photos"
        ]
        if let name = known[id] { return name }
        return id.split(separator: ".").last.map(String.init) ?? id
    }

    // MARK: - Making events

    private static let siteChecks = ["adult-site", "adult-search", "adult-community", "adult-title"]

    private static func siteStepTitle(_ check: String) -> String {
        switch check {
        case "adult-site": return "Address check (adult site lists and domain rules)"
        case "adult-search": return "Search check (explicit words and phrases in the search)"
        case "adult-community": return "Reddit check (adult communities and explicit post titles)"
        default: return "Page-title check (only when the browser hides the address)"
        }
    }

    private static func siteNoMatch(_ check: String) -> String {
        switch check {
        case "adult-site": return "The address is not on the built-in or downloaded adult-site lists and has no adult keyword or domain ending."
        case "adult-search": return "No explicit word, phrase or fragment in the search (or the address has no search)."
        default: return "Not an adult Reddit community or an explicit post title (or not Reddit)."
        }
    }

    /// An event for a rule match on an address (adult site, explicit search, adult community, page title). The
    /// steps list the checks in the order they run, so it is clear which one matched and what the others said.
    public static func website(check: String, reason: AdultSiteMatcher.MatchReason, page: String?, app: String?, date: Date = Date()) -> BlockEvent {
        var details = [
            Detail("Check", checkName(check)),
            Detail("Rule", ruleName(reason.rule)),
            Detail("Matched", reason.matched)
        ]
        if check == "adult-search" {
            details.append(Detail("Search words", "Not saved. Only the rule that matched is kept."))
        }

        let position = siteChecks.firstIndex(of: check) ?? 0
        var steps: [Step] = []
        for (index, name) in siteChecks.enumerated() {
            let title = siteStepTitle(name)
            if name == check {
                steps.append(Step(title, .decided, reason.detail + " Rule: \(ruleName(reason.rule)); entry that matched: \(reason.matched)."))
            } else if name == "adult-title" {
                steps.append(Step(title, .skipped, "Not used: the browser showed the page address."))
            } else if check == "adult-title" {
                steps.append(Step(title, .skipped, "Not possible: the browser did not show the page address."))
            } else if index < position {
                steps.append(Step(title, .clear, siteNoMatch(name)))
            } else {
                steps.append(Step(title, .skipped, "Not needed: an earlier check already matched."))
            }
        }

        var assessment = "Closed by a built-in rule: \(ruleName(reason.rule)). Built-in adult rules are a hard block with no unlock or allow list."
        if check == "adult-search" { assessment += " Only the rule that matched is kept, not the words that were searched." }
        return BlockEvent(date: date, kind: .website, check: check, headline: headline(forCheck: check), why: reason.detail,
                          action: "Tab closed", page: page, app: app, details: details, steps: steps, assessment: assessment)
    }

    /// An event for the page-text safety net.
    public static func pageText(score: Int, distinct: Int, terms: [String], page: String?, app: String?, date: Date = Date()) -> BlockEvent {
        let led = terms.prefix(5).joined(separator: ", ")
        let why = "The words visible on the page scored \(score) (a page is closed at \(AdultContentScorer.threshold) or more) "
            + "from \(distinct) different explicit terms (it takes \(AdultContentScorer.minimumDistinctTerms) or more)"
            + (led.isEmpty ? "." : ", led by \(led).") + " The page text itself is not saved."
        let details = [
            Detail("Check", checkName("page-text")),
            Detail("Score", "\(score) (closed at \(AdultContentScorer.threshold) or more)"),
            Detail("Different terms", "\(distinct) (needs \(AdultContentScorer.minimumDistinctTerms) or more)"),
            Detail("Main terms", terms.isEmpty ? "none recorded" : terms.joined(separator: ", "))
        ]
        let steps = [
            Step("Address and search checks", .clear, "The address and search passed the adult-site, explicit-search and Reddit rules."),
            Step("Everyday-site exemption", .clear, "Not exempt: this site is not one of the everyday sites (video, reference, shops, news, social feeds) that are never judged by their text."),
            Step("Page-text scorer", .decided, "The visible text scored \(score) against a limit of \(AdultContentScorer.threshold), from \(distinct) different explicit terms (it needs \(AdultContentScorer.minimumDistinctTerms)). "
                + (led.isEmpty ? "" : "Main terms: \(led). ") + "It reads only the words on the page, and is deliberately hard to trip.")
        ]
        let assessment = "Closed by the page-text safety net: the visible text scored \(score) (limit \(AdultContentScorer.threshold)) from \(distinct) different explicit terms. "
            + "This catches adult pages that no list knows, so it judges words only; it did not see the pictures."
        return BlockEvent(date: date, kind: .website, check: "page-text", headline: headline(forCheck: "page-text"), why: why,
                          action: "Tab closed", page: page, app: app, details: details, steps: steps, assessment: assessment)
    }

    /// An event for the screen image scanner. `scores` are the raw scores, `decided` the ones the verdict used
    /// (a coarse hit the finer tiles did not back up is zeroed there), `looksLike` the labels from the general
    /// picture classifier for the flagged part of the screen (may be empty), `bodyParts` what the body-part
    /// detector found there (nil when its model is not installed).
    public static func image(outcome: Outcome, nearMiss: ImageScanLogic.NearMiss? = nil, scores: [Double], decided: [Double],
                             strict: Bool, looksLike: String, bodyParts: [BodyPartLogic.Detection]? = nil,
                             memory: FeedbackLogic.Match? = nil, memoryCount: Int = 0,
                             action: String, page: String?, app: String?, date: Date = Date()) -> BlockEvent {
        // A held-back event is about the score that was set aside, so it reads from the raw scores.
        let basis = nearMiss == .heldBack ? scores : decided
        let top = basis.max() ?? 0
        let index = basis.firstIndex(of: top) ?? 0
        let region = ImageScanLogic.regionName(ofTile: index, count: basis.count)
        let kind = nearMiss ?? .belowBar
        let check: String
        var why: String
        if outcome == .blocked {
            check = "image-scan"
            why = ImageScanLogic.explanation(scores: decided, strict: strict, raw: scores) + "."
        } else {
            switch kind {
            case .recheck: check = "image-recheck"
            case .belowBar: check = "image-near-miss"
            case .heldBack: check = "image-held-back"
            case .notConfirmed: check = "image-not-confirmed"
            case .matchesNotExplicit: check = "image-learned-hold"
            }
            why = ImageScanLogic.nearMissExplanation(scores: decided, strict: strict, kind: kind, raw: scores)
        }

        // What the body-part detector found in the flagged area (nil: it is not installed, so nothing is said).
        let parts = bodyParts.map { BodyPartLogic.summarise($0) }
        // Explicit findings belong in the reason; "found nothing explicit" is explained in the steps and assessment.
        if let parts = parts, !parts.explicit.isEmpty { why += " " + BodyPartLogic.sentence(parts) }

        let percent = ImageScanLogic.percent
        let hit = strict ? ImageScanLogic.searchHitScore : ImageScanLogic.hitScore
        let suspect = strict ? ImageScanLogic.searchSuspectScore : ImageScanLogic.suspectScore
        let bars = "\(percent(hit)) to act on one scan, \(percent(suspect)) on two in a row" + (strict ? " (stricter because this is a search-results page)" : "")

        var details = [
            Detail("Check", checkName(check)),
            Detail("Flagged area", region),
            Detail("Model score", percent(top) + " explicit")
        ]
        if outcome == .blocked {
            details.append(Detail("Bar cleared", top >= hit
                ? "\(percent(hit)) (acts on one scan)"
                : "\(percent(suspect)) on two scans in a row"))
        } else {
            details.append(Detail("Bar to act", "\(percent(suspect)) on two scans, \(percent(hit)) on one"))
        }
        if strict { details.append(Detail("Page type", "Search results, so the stricter bars apply")) }

        let others = basis.indices
            .filter { $0 != index && basis[$0] >= ImageScanLogic.noteScore }
            .sorted { basis[$0] > basis[$1] }
            .prefix(4)
            .map { "\(ImageScanLogic.regionName(ofTile: $0, count: basis.count)) \(percent(basis[$0]))" }
        details.append(Detail("Also high", others.isEmpty ? "Nothing else above \(percent(ImageScanLogic.noteScore))" : others.joined(separator: ", ")))

        let setAside = raw(scores, differsFrom: decided)
            ? scores.indices.filter { scores[$0] != decided[$0] }
                .map { "\(ImageScanLogic.regionName(ofTile: $0, count: scores.count)) \(percent(scores[$0]))" }
            : []
        if !setAside.isEmpty {
            details.append(Detail("Set aside", setAside.joined(separator: ", ") + " (the finer tiles inside did not agree)"))
        }
        if let parts = parts {
            details.append(Detail("Body parts found", parts.explicit.isEmpty ? "None explicit" : parts.explicit.joined(separator: ", ")))
            details.append(Detail("Also seen", parts.context.isEmpty ? "Nothing else" : parts.context.joined(separator: ", ")))
        }
        if !looksLike.isEmpty {
            details.append(Detail("Apple classifier says", looksLike + " (a general picture classifier, not the explicit-content model)"))
        }

        // The decision, stage by stage.
        var steps: [Step] = []
        switch (outcome, kind) {
        case (.blocked, _):
            steps.append(Step("Image model (this decided the block)", .decided,
                "The \(region) scored \(percent(top)) explicit. Bars: \(bars). "
                + (top >= hit ? "It cleared the one-scan bar, so the tab was closed at once." : "It cleared the repeat bar on two scans in a row, so the tab was closed.")))
        case (_, .recheck):
            steps.append(Step("Image model", .context, "The \(region) scored \(percent(top)) explicit, above the repeat bar. The tab closes only if the next scan scores that high again."))
        case (_, .heldBack):
            steps.append(Step("Image model", .context, "The \(region) scored \(percent(top)) explicit, which would have been enough on its own. See the finer-tile check."))
        case (_, .notConfirmed), (_, .matchesNotExplicit):
            steps.append(Step("Image model (proposed closing it)", .context,
                "The \(region) scored \(percent(top)) explicit, enough to close on its own. The model is overconfident, so it needs a second check before anything is closed. Bars: \(bars)."))
        case (_, .belowBar):
            steps.append(Step("Image model", .clear, "The \(region) scored \(percent(top)) explicit. Bars: \(bars). Under both, so nothing was closed."))
        }

        let tiles = ImageScanLogic.tiles(width: 1280, height: 800)
        if basis.count == tiles.count, outcome == .blocked || kind != .belowBar {
            let floor = percent(ImageScanLogic.corroborationFloor)
            if let backing = ImageScanLogic.strongestFinerTile(forTile: index, scores: scores, tiles: tiles) {
                let tile = ImageScanLogic.regionName(ofTile: backing.index, count: tiles.count)
                if backing.score >= ImageScanLogic.corroborationFloor {
                    steps.append(Step("Finer-tile check", .supports,
                        "Backed up: the \(tile) inside it scored \(percent(backing.score)). A whole-screen or quarter hit needs a finer tile inside it at \(floor) or more."
                        + (setAside.isEmpty ? "" : " Set aside for lack of that: \(setAside.joined(separator: ", ")).")))
                } else {
                    steps.append(Step("Finer-tile check", .against,
                        "No finer tile inside the \(region) reached \(floor) (best: the \(tile) at \(percent(backing.score))), so that hit was set aside as the model misreading a busy screen."))
                }
            } else {
                steps.append(Step("Finer-tile check", .context,
                    "Not needed: the flagged area is already one of the smallest tiles (a ninth of the screen), so there is nothing finer to check it against."
                    + (setAside.isEmpty ? "" : " Set aside elsewhere: \(setAside.joined(separator: ", ")).")))
            }
        }

        let confirmed = bodyParts.map { BodyPartLogic.confirms($0) }
        if let parts = parts {
            let seen = parts.context.isEmpty ? "" : " It saw only: " + parts.context.joined(separator: ", ") + "."
            if confirmed == true {
                steps.append(Step("Body-part detector (second opinion)", .supports,
                    "It found explicit body parts in that area: \(parts.explicit.joined(separator: ", ")).\(parts.context.isEmpty ? "" : " Also seen: " + parts.context.joined(separator: ", ") + ".")"))
            } else {
                // Either nothing explicit, or only a weak sign of it (under the confidence needed to confirm).
                let weak = parts.explicit.isEmpty ? ""
                    : " It saw only weak signs of an explicit body part (\(parts.explicit.joined(separator: ", "))); it needs \(percent(Double(BodyPartLogic.confirmationScore))) or more."
                steps.append(Step("Body-part detector (second opinion)", .against,
                    "It found no explicit body part in that area it was sure of." + weak + (parts.context.isEmpty ? (parts.explicit.isEmpty ? " It found nothing at all." : "") : seen)
                    + (kind == .notConfirmed && outcome == .nearMiss ? " That is why nothing was closed." : "")
                    + " It is trained on photos, so drawn, stylised or unusual pictures, and small or partly hidden parts, are often missed. What it sees besides explicit parts (a face, say) is not a reason for a block."))
            }
        } else {
            steps.append(Step("Body-part detector (second opinion)", .skipped, "Not run: its model is not installed (see the README)."))
        }

        if looksLike.isEmpty {
            steps.append(Step("Apple picture classifier (context only)", .skipped, "No labels were recorded."))
        } else {
            let lowered = looksLike.lowercased()
            let page = lowered.contains("screenshot") || lowered.contains("document")
                ? " Labels like screenshot or document mean the area looks like a page or window rather than a single photo."
                : ""
            steps.append(Step("Apple picture classifier (context only)", .context,
                "It describes the area as: \(looksLike). It has no nudity labels, so it can neither confirm nor rule out explicit content.\(page)"))
        }

        // What the user has taught it.
        if let memory = memory {
            let how = ImageScanLogic.percent(memory.similarity)
            let said = memory.label == .explicit ? "explicit" : "not explicit"
            if memory.label == .notExplicit && confirmed == true {
                steps.append(Step("Your earlier corrections", .against,
                    "This looks like a picture you marked as \(said) (\(how) alike), but the body-part detector found an explicit body part, and that always wins."))
            } else if memory.label == .notExplicit {
                steps.append(Step("Your earlier corrections", .decided,
                    "This looks like a picture you marked as \(said) (\(how) alike), so it was held, not closed."))
            } else if confirmed == true {
                steps.append(Step("Your earlier corrections", .supports,
                    "This also looks like a picture you marked as \(said) (\(how) alike)."))
            } else {
                steps.append(Step("Your earlier corrections", .decided,
                    "This looks like a picture you marked as \(said) (\(how) alike), so it was closed although the body-part detector did not find an explicit body part."))
            }
        } else if memoryCount > 0 {
            steps.append(Step("Your earlier corrections", .clear,
                "Nothing you have marked looks close enough to this (it takes \(ImageScanLogic.percent(FeedbackLogic.matchThreshold)) alike). You have marked \(memoryCount) so far."))
        }

        // What it adds up to.
        var assessment: String
        var confidence: Confidence?
        if outcome == .blocked, let memory = memory, memory.label == .explicit, confirmed != true {
            assessment = "Closed because this looks like a picture you marked as explicit (\(percent(memory.similarity)) alike), although the body-part detector did not find an explicit body part there. The image model scored the \(region) \(percent(top)) explicit."
            confidence = .learned
        } else if outcome == .blocked {
            let head = "Closed on the image model's score alone: the \(region) scored \(percent(top)) explicit."
            if let parts = parts {
                if confirmed != true {
                    let seen = parts.context.isEmpty ? "" : " (it saw only " + parts.context.joined(separator: ", ") + ", which is not a reason for the block)"
                    assessment = head + " The body-part detector found no explicit body part there\(seen), so the second opinion did not agree: a weaker block."
                    confidence = .modelOnly
                } else {
                    assessment = "Closed: the image model scored the \(region) \(percent(top)) explicit, and the body-part detector independently found \(parts.explicit[0])."
                    confidence = .corroborated
                }
            } else {
                assessment = head + " The body-part detector is not installed, so there was no second opinion."
                confidence = .notCrossChecked
            }
        } else {
            switch kind {
            case .recheck: assessment = "Not closed yet: the \(region) scored \(percent(top)) explicit, above the repeat bar. It closes only if the next scan scores that high again."
            case .belowBar: assessment = "Nothing closed: the \(region) scored \(percent(top)) explicit, under the \(percent(suspect)) bar."
            case .heldBack: assessment = "Nothing closed: a high score in the \(region) was set aside because no finer tile inside it agreed."
            case .matchesNotExplicit:
                assessment = "Nothing closed: this looks like a picture you marked as not explicit (\(percent(memory?.similarity ?? 0)) alike), although the image model scored the \(region) \(percent(top)) explicit. If it was explicit after all, mark this entry \u{201C}explicit\u{201D} and it will be closed next time."
            case .notConfirmed:
                let seen = parts.map { $0.context.isEmpty ? "" : " (it saw only " + $0.context.joined(separator: ", ") + ")" } ?? ""
                assessment = "Nothing closed: the image model scored the \(region) \(percent(top)) explicit, but the body-part detector found no explicit body part there\(seen), so the second opinion did not confirm it. "
                    + "Looks like this (a finger, food, a skin-tone close-up) used to close apps wrongly. If it really was explicit, the detector missed it: the Settings option \u{201C}Close images only when a second check agrees\u{201D} can be turned off."
            }
        }

        return BlockEvent(date: date, kind: .image, outcome: outcome, check: check, headline: headline(forCheck: check), why: why,
                          action: action, page: page, app: app, details: details, scores: scores, strict: strict,
                          steps: steps, assessment: assessment, confidence: confidence)
    }

    private static func raw(_ scores: [Double], differsFrom decided: [Double]) -> Bool {
        scores.count == decided.count && scores != decided
    }

    // MARK: - Filtering and grouping (for the window)

    public enum Filter: Int, CaseIterable {
        case blocks, images, websites, nearMisses
    }

    public func matches(_ filter: Filter) -> Bool {
        switch filter {
        case .blocks: return outcome == .blocked
        case .images: return outcome == .blocked && kind == .image
        case .websites: return outcome == .blocked && kind == .website
        case .nearMisses: return outcome == .nearMiss
        }
    }

    /// Whether every word of `search` appears in the headline, reason, page, app name, check or details.
    public func matches(search: String) -> Bool {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([headline, why, page ?? "", BlockEvent.appName(app), action, BlockEvent.checkName(check)]
            + details.map { $0.label + " " + $0.value }).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// `Today`, `Yesterday`, or a date like `Mon 9 Nov` (with the year once it is not this year).
    public static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "EEE d MMM" : "EEE d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `22:37` (the day is in the section heading).
    public static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        return (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
    }

    /// How many blocks (not near misses) there were today, in the last seven days, in all, and of which kind.
    public static func counts(_ events: [BlockEvent], now: Date = Date(), calendar: Calendar = .current)
        -> (today: Int, week: Int, total: Int, images: Int, websites: Int) {
        let blocks = events.filter { $0.outcome == .blocked }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        return (
            today: blocks.filter { calendar.isDate($0.date, inSameDayAs: now) }.count,
            week: blocks.filter { $0.date >= weekAgo }.count,
            total: blocks.count,
            images: blocks.filter { $0.kind == .image }.count,
            websites: blocks.filter { $0.kind == .website }.count
        )
    }

    /// Images and website blocks (not near misses) on or after `start`.
    public static func breakdown(_ events: [BlockEvent], since start: Date) -> (images: Int, websites: Int) {
        let blocks = events.filter { $0.outcome == .blocked && $0.date >= start }
        return (blocks.filter { $0.kind == .image }.count, blocks.filter { $0.kind == .website }.count)
    }

    // MARK: - Text

    /// The event as a single line for `blocks.log`.
    public var logLine: String {
        var parts = ["\(headline)", "check=\(check)", "why=\"\(why)\""]
        if let assessment = assessment { parts.append("in-short=\"\(assessment)\"") }
        if let confidence = confidence { parts.append("confidence=\(confidence.rawValue)") }
        if let steps = steps {
            parts.append("steps=[" + steps.map { "\($0.result.tag): \($0.title)" }.joined(separator: "; ") + "]")
        }
        for detail in details where detail.label != "Check" { parts.append("\(detail.label)=\(detail.value)") }
        if let scores = scores {
            parts.append("scores(whole | 2x2 | 3x3)=[" + scores.map { String(format: "%.3f", $0) }.joined(separator: " ") + "]")
        }
        parts.append("action=\(action)")
        parts.append("app=\(app ?? "?")")
        parts.append("page=\(page ?? "(none)")")
        return parts.joined(separator: "  ")
    }

    /// A readable copy of the whole event, for pasting into a note or a bug report.
    public var copyText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [headline, formatter.string(from: date) + "  ·  " + action + "  ·  " + BlockEvent.appName(app)]
        if let page = page { lines.append("Page: " + page) }
        lines.append("")
        if let assessment = assessment {
            lines.append("In short: " + assessment + (confidence.map { " [" + $0.label + "]" } ?? ""))
            lines.append("")
        }
        lines.append("Why: " + why)
        if let steps = steps, !steps.isEmpty {
            lines.append("")
            lines.append("How the decision was made:")
            for (index, step) in steps.enumerated() {
                lines.append("  \(index + 1). [\(step.result.tag)] \(step.title)")
                lines.append("     \(step.detail)")
            }
        }
        lines.append("")
        for detail in details { lines.append("\(detail.label): \(detail.value)") }
        if let scores = scores {
            lines.append("Scores (whole | 2x2 | 3x3): " + scores.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Older log lines

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// The text that follows `key` up to the next space.
    private static func word(after key: String, in text: String) -> String? {
        guard let range = text.range(of: key) else { return nil }
        let value = text[range.upperBound...].prefix { $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    /// The text between the `[` that follows `key` and the next `]`.
    private static func bracket(after key: String, in text: String) -> String? {
        guard let range = text.range(of: key), let open = text[range.upperBound...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    /// Reads one line of the older plain-text `blocks.log` (written before there was a Block Log window) as an
    /// event, so earlier blocks still show. Returns nil for lines that are not blocks (the score trace) or that
    /// cannot be read.
    public static func legacy(line: String) -> BlockEvent? {
        guard line.count > 24, let date = stampFormatter.date(from: String(line.prefix(19))) else { return nil }
        let rest = String(line.dropFirst(21))
        let parts = rest.components(separatedBy: "  ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let source = parts[0]
        let what = parts[1]
        let page = word(after: "page=", in: rest)

        if source == "website" {
            let app: String? = nil
            switch what {
            case "adult-site", "adult-search", "adult-community":
                let why: String
                switch what {
                case "adult-site": why = "The address matched the adult-site list or rules. (This entry is from before reasons were recorded, so which rule is not known.)"
                case "adult-search": why = "The search matched the explicit-search rules. (Recorded before reasons were kept, so the matching term is not known.)"
                default: why = "The Reddit community or post title matched the adult-community rules. (Recorded before reasons were kept.)"
                }
                return BlockEvent(date: date, kind: .website, check: what, headline: headline(forCheck: what), why: why, action: "Tab closed",
                                  page: page, app: app, details: [Detail("Check", checkName(what))])
            case "adult-title":
                return BlockEvent(date: date, kind: .website, check: what, headline: headline(forCheck: what),
                                  why: "The browser did not show the page address, and the page title matched an adult keyword.", action: "Tab closed",
                                  page: nil, app: app, details: [Detail("Check", checkName(what))])
            case "page-text":
                let score = Int(word(after: "score=", in: rest) ?? "") ?? 0
                let distinct = Int(word(after: "distinct-terms=", in: rest) ?? "") ?? 0
                let terms = (bracket(after: "top-terms=", in: rest) ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }
                var event = pageText(score: score, distinct: distinct, terms: terms, page: page, app: app, date: date)
                event.id = UUID().uuidString
                return event
            default:
                return nil
            }
        }

        if source == "image-scanner" {
            let blocked = what.hasPrefix("EXPLICIT")
            let recheck = what.hasPrefix("suspect")
            let midScore = what.hasPrefix("mid-score")
            guard blocked || recheck || midScore else { return nil }
            let scores = (bracket(after: "scores(", in: rest) ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            let strict = word(after: "strict=", in: rest) == "true"
            let app = word(after: "app=", in: rest)
            if scores.count == 14 {
                let kind: ImageScanLogic.NearMiss = (what.contains("held back")) ? .heldBack : (recheck ? .recheck : .belowBar)
                return image(outcome: blocked ? .blocked : .nearMiss, nearMiss: blocked ? nil : kind, scores: scores, decided: scores, strict: strict,
                             looksLike: bracket(after: "looks-like=", in: rest) ?? "", action: blocked ? "Tab closed" : "Nothing closed",
                             page: page, app: app, date: date)
            }
            // The first scanner log had one score for the whole screen and one per quarter.
            let top = scores.max() ?? 0
            let check = blocked ? "image-scan" : (recheck ? "image-recheck" : "image-near-miss")
            return BlockEvent(date: date, kind: .image, outcome: blocked ? .blocked : .nearMiss, check: check, headline: headline(forCheck: check),
                              why: "The model scored the screen \(ImageScanLogic.percent(top)) explicit at its highest. (Recorded by an older version, which kept only five scores, so the region is not known.)",
                              action: blocked ? "Tab closed" : "Nothing closed", page: page, app: app,
                              details: [Detail("Check", checkName(check)), Detail("Model score", ImageScanLogic.percent(top) + " explicit")],
                              scores: nil, strict: strict)
        }
        return nil
    }
}
