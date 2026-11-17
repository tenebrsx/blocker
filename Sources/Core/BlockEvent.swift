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

    public init(id: String = UUID().uuidString, date: Date = Date(), kind: Kind, outcome: Outcome = .blocked, check: String,
                headline: String, why: String, action: String, page: String? = nil, app: String? = nil,
                details: [Detail] = [], scores: [Double]? = nil, strict: Bool? = nil) {
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
        case "image-scan", "image-recheck", "image-near-miss", "image-held-back": return "Screen image scanner"
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

    /// An event for a rule match on an address (adult site, explicit search, adult community, page title).
    public static func website(check: String, reason: AdultSiteMatcher.MatchReason, page: String?, app: String?, date: Date = Date()) -> BlockEvent {
        var details = [
            Detail("Check", checkName(check)),
            Detail("Rule", ruleName(reason.rule)),
            Detail("Matched", reason.matched)
        ]
        if check == "adult-search" {
            details.append(Detail("Search words", "Not saved. Only the rule that matched is kept."))
        }
        return BlockEvent(date: date, kind: .website, check: check, headline: headline(forCheck: check), why: reason.detail,
                          action: "Tab closed", page: page, app: app, details: details)
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
        return BlockEvent(date: date, kind: .website, check: "page-text", headline: headline(forCheck: "page-text"), why: why,
                          action: "Tab closed", page: page, app: app, details: details)
    }

    /// An event for the screen image scanner. `scores` are the raw scores, `decided` the ones the verdict used
    /// (a coarse hit the finer tiles did not back up is zeroed there), `looksLike` the labels from the general
    /// picture classifier for the flagged part of the screen (may be empty).
    public static func image(outcome: Outcome, nearMiss: ImageScanLogic.NearMiss? = nil, scores: [Double], decided: [Double],
                             strict: Bool, looksLike: String, bodyParts: [BodyPartLogic.Detection]? = nil,
                             action: String, page: String?, app: String?, date: Date = Date()) -> BlockEvent {
        // A held-back event is about the score that was set aside, so it reads from the raw scores.
        let basis = nearMiss == .heldBack ? scores : decided
        let top = basis.max() ?? 0
        let index = basis.firstIndex(of: top) ?? 0
        let region = ImageScanLogic.regionName(ofTile: index, count: basis.count)
        let check: String
        let why: String
        if outcome == .blocked {
            check = "image-scan"
            why = ImageScanLogic.explanation(scores: decided, strict: strict, raw: scores) + "."
        } else {
            let kind = nearMiss ?? .belowBar
            switch kind {
            case .recheck: check = "image-recheck"
            case .belowBar: check = "image-near-miss"
            case .heldBack: check = "image-held-back"
            }
            why = ImageScanLogic.nearMissExplanation(scores: decided, strict: strict, kind: kind, raw: scores)
        }

        // What the body-part detector found in the flagged area (nil: it is not installed, so nothing is said).
        let parts = bodyParts.map { BodyPartLogic.summarise($0) }
        let whyWithParts = parts.map { why + " " + BodyPartLogic.sentence($0) } ?? why

        var details = [
            Detail("Check", checkName(check)),
            Detail("Flagged area", region),
            Detail("Model score", ImageScanLogic.percent(top) + " explicit")
        ]
        let hit = strict ? ImageScanLogic.searchHitScore : ImageScanLogic.hitScore
        let suspect = strict ? ImageScanLogic.searchSuspectScore : ImageScanLogic.suspectScore
        if outcome == .blocked {
            details.append(Detail("Bar cleared", top >= hit
                ? "\(ImageScanLogic.percent(hit)) (acts on one scan)"
                : "\(ImageScanLogic.percent(suspect)) on two scans in a row"))
        } else {
            details.append(Detail("Bar to act", "\(ImageScanLogic.percent(suspect)) on two scans, \(ImageScanLogic.percent(hit)) on one"))
        }
        if strict { details.append(Detail("Page type", "Search results, so the stricter bars apply")) }

        let others = basis.indices
            .filter { $0 != index && basis[$0] >= ImageScanLogic.noteScore }
            .sorted { basis[$0] > basis[$1] }
            .prefix(4)
            .map { "\(ImageScanLogic.regionName(ofTile: $0, count: basis.count)) \(ImageScanLogic.percent(basis[$0]))" }
        details.append(Detail("Also high", others.isEmpty ? "Nothing else above \(ImageScanLogic.percent(ImageScanLogic.noteScore))" : others.joined(separator: ", ")))

        if raw(scores, differsFrom: decided) {
            let aside = scores.indices.filter { scores[$0] != decided[$0] }
                .map { "\(ImageScanLogic.regionName(ofTile: $0, count: scores.count)) \(ImageScanLogic.percent(scores[$0]))" }
            details.append(Detail("Set aside", aside.joined(separator: ", ") + " (the finer tiles inside did not agree)"))
        }
        if let parts = parts {
            details.append(Detail("Body parts found", parts.explicit.isEmpty ? "None explicit" : parts.explicit.joined(separator: ", ")))
            details.append(Detail("Also seen", parts.context.isEmpty ? "Nothing else" : parts.context.joined(separator: ", ")))
        }
        if !looksLike.isEmpty {
            details.append(Detail("Apple classifier says", looksLike + " (a general picture classifier, not the explicit-content model)"))
        }

        return BlockEvent(date: date, kind: .image, outcome: outcome, check: check, headline: headline(forCheck: check), why: whyWithParts,
                          action: action, page: page, app: app, details: details, scores: scores, strict: strict)
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
        lines.append("Why: " + why)
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
