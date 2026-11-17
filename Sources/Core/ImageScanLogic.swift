/// The decisions behind the screen image scanner, kept free of screen capture and machine learning so they
/// can be unit-tested. Most of this is about saving battery: the model only runs when the screen has
/// actually changed, and the scan rate backs off when nothing is happening.
public enum ImageScanLogic {

    // MARK: - Thresholds

    /// A region this likely to be explicit is acted on immediately. Very high on purpose: a wrongly blacked
    /// out page costs more than a late catch, and image models are over-eager on skin tones, beach and
    /// gym photos, and film stills.
    public static let hitScore = 0.99

    /// A region this likely to be explicit is checked again on the next scan; two in a row is acted on.
    public static let suspectScore = 0.93

    /// On a search engine's results page the screen is a mosaic of small photos, which the model was not
    /// trained on and misreads far more often than a single picture (a search for "stanford students"
    /// closed a tab). The address and the search words are already checked by text rules there, so the
    /// picture model needs to be much more sure before it may act.
    public static let searchHitScore = 0.998
    public static let searchSuspectScore = 0.995

    /// A score at or above this that is still below the bar is written to the block log (at most every 20
    /// seconds), so that what the model gives to real pictures it missed can be seen and the bar tuned.
    public static let noteScore = 0.5

    /// How much the screen must change (mean brightness difference of a tiny thumbnail, 0...1) before the
    /// model is run again. About 1.5% is a few brightness levels on average: a new picture or a scroll
    /// clears it, a blinking cursor or a clock does not.
    public static let changeThreshold = 0.015

    public static let thumbnailWidth = 32
    public static let thumbnailHeight = 20

    // MARK: - Change detection

    /// Mean absolute difference between two same-sized grey thumbnails, 0 (identical) ... 1 (opposite).
    public static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total = 0
        for index in 0..<first.count {
            total += abs(Int(first[index]) - Int(second[index]))
        }
        return Double(total) / Double(first.count) / 255.0
    }

    // MARK: - Tiling

    public struct Tile: Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    /// The long side, in pixels, of the screenshot the model looks at. A picture in a feed (Reddit, X) takes up
    /// only a slice of the screen, so at the old 640 px a post's image was a blurry 120 px patch; the model
    /// misses what it can't make out. 1280 px keeps such a picture at a size the model can read.
    public static let captureLongSide = 1280.0

    /// `columns` x `rows` equal tiles, row by row. Edges are rounded so the tiles cover the image exactly.
    public static func grid(width: Int, height: Int, columns: Int, rows: Int) -> [Tile] {
        var result: [Tile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let left = column * width / columns
                let right = (column + 1) * width / columns
                let top = row * height / rows
                let bottom = (row + 1) * height / rows
                result.append(Tile(x: left, y: top, width: right - left, height: bottom - top))
            }
        }
        return result
    }

    /// The whole screen, a 2x2 grid and a 3x3 grid (14 looks). Shrinking a whole screen to the model's input
    /// size loses a small picture, and a picture in a feed sits in the middle of the screen, spread across
    /// several quarters; the finer grid gives it a tile of its own. Order: whole, then 2x2 row by row, then
    /// 3x3 row by row.
    public static func tiles(width: Int, height: Int) -> [Tile] {
        guard width >= 3, height >= 3 else { return [Tile(x: 0, y: 0, width: max(width, 1), height: max(height, 1))] }
        return [Tile(x: 0, y: 0, width: width, height: height)]
            + grid(width: width, height: height, columns: 2, rows: 2)
            + grid(width: width, height: height, columns: 3, rows: 3)
    }

    // MARK: - Corroboration

    /// A coarse look (the whole screen or a quarter) that scores very high must be backed up by at least one of
    /// the finer tiles inside it scoring at least this much. A real explicit picture shows in the crops that
    /// contain it; the model's blind spots (a mosaic of Google Images thumbnails, a busy feed) show up in a
    /// big downscaled look only. A search for "the hangover mike tyson" scored 1.000 on one quarter of the
    /// screen while every 3x3 tile inside that quarter was under 0.06, and closed the tab.
    public static let corroborationFloor = 0.15

    /// How much of `inner` lies inside `outer`, 0...1.
    static func overlap(of inner: Tile, inside outer: Tile) -> Double {
        let area = inner.width * inner.height
        guard area > 0 else { return 0 }
        let width = min(inner.x + inner.width, outer.x + outer.width) - max(inner.x, outer.x)
        let height = min(inner.y + inner.height, outer.y + outer.height) - max(inner.y, outer.y)
        guard width > 0, height > 0 else { return 0 }
        return Double(width * height) / Double(area)
    }

    /// The tiles finer than `tiles[index]` that lie mostly inside it: at most about half its area, with a quarter or
    /// more of themselves inside it.
    static func finerTileIndices(of index: Int, in tiles: [Tile]) -> [Int] {
        let tile = tiles[index]
        let tileArea = tile.width * tile.height
        return tiles.indices.filter { other in
            tiles[other].width * tiles[other].height * 2 < tileArea && overlap(of: tiles[other], inside: tile) >= 0.25
        }
    }

    /// The finer tile inside `tiles[index]` with the highest score, or nil when nothing finer lies inside it (a 3x3 tile).
    public static func strongestFinerTile(forTile index: Int, scores: [Double], tiles: [Tile]) -> (index: Int, score: Double)? {
        guard scores.count == tiles.count, index >= 0, index < tiles.count else { return nil }
        guard let best = finerTileIndices(of: index, in: tiles).max(by: { scores[$0] < scores[$1] }) else { return nil }
        return (best, scores[best])
    }

    /// The scores with every uncorroborated coarse hit set to 0. A tile is only questioned when it scores high
    /// enough to matter (at the lowest bar, `suspectScore`) and has finer tiles inside it; the finest tiles
    /// (the 3x3 grid) have nothing finer to be checked against, so a small picture caught only at that scale
    /// is left alone. `tiles` are the tiles the scores were made from, in the same order.
    public static func supportedScores(_ scores: [Double], tiles: [Tile]) -> [Double] {
        guard scores.count == tiles.count else { return scores }
        var result = scores
        for index in tiles.indices where scores[index] >= suspectScore {
            let finer = finerTileIndices(of: index, in: tiles)
            guard !finer.isEmpty else { continue }
            if !finer.contains(where: { scores[$0] >= corroborationFloor }) { result[index] = 0 }
        }
        return result
    }

    // MARK: - Verdict

    public enum Verdict: Equatable {
        case clear
        case suspect
        case explicit
    }

    /// `scores` are the model's "explicit" probabilities for each tile of one scan.
    public static func verdict(scores: [Double], previouslySuspect: Bool, onSearchResults: Bool = false) -> Verdict {
        let top = scores.max() ?? 0
        let hit = onSearchResults ? searchHitScore : hitScore
        let suspect = onSearchResults ? searchSuspectScore : suspectScore
        if top >= hit { return .explicit }
        if top >= suspect { return previouslySuspect ? .explicit : .suspect }
        return .clear
    }

    // MARK: - Explaining a block

    /// Where on the screen a tile is, in words, for the standard 14-tile layout (whole, 2x2, 3x3).
    public static func regionName(ofTile index: Int, count: Int) -> String {
        guard count == 14, index >= 0, index < count else { return "tile \(index)" }
        if index == 0 { return "whole screen" }
        if index <= 4 {
            return ["top-left", "top-right", "bottom-left", "bottom-right"][index - 1] + " quarter of the screen"
        }
        return ["top-left", "top-centre", "top-right", "middle-left", "centre", "middle-right",
                "bottom-left", "bottom-centre", "bottom-right"][index - 5] + " ninth of the screen"
    }

    /// `0.9985` as `99.9%` (no Foundation, so tests and logs agree on the rounding).
    public static func percent(_ value: Double) -> String {
        let tenths = Int((min(max(value, 0), 1) * 1000).rounded())
        return "\(tenths / 10).\(tenths % 10)%"
    }

    /// The reason for a block as one plain sentence: which part of the screen the model was looking at, how sure
    /// it was and which bar that cleared, and which other tiles agreed. The model gives one number per look (how
    /// likely the picture is explicit); it does not name what it sees, so this is as specific as the scores allow.
    /// `raw` are the scores before `supportedScores` set any aside; when given and different, the sentence also
    /// says which tiles were set aside and why.
    public static func explanation(scores: [Double], strict: Bool, raw: [Double]? = nil) -> String {
        guard let top = scores.max(), let index = scores.firstIndex(of: top) else { return "no scores" }
        let where_ = regionName(ofTile: index, count: scores.count)
        let hit = strict ? searchHitScore : hitScore
        let suspect = strict ? searchSuspectScore : suspectScore
        var sentence = "\(where_) scored \(percent(top)) explicit"
        if top >= hit {
            sentence += ", at or above the \(percent(hit)) bar for acting straight away"
        } else {
            sentence += " on two scans in a row, above the \(percent(suspect)) bar for a repeat sighting"
        }
        if strict { sentence += " (a search-results page, so the stricter bars)" }

        let others = scores.indices
            .filter { $0 != index && scores[$0] >= noteScore }
            .sorted { scores[$0] > scores[$1] }
            .prefix(4)
            .map { "\(regionName(ofTile: $0, count: scores.count)) \(percent(scores[$0]))" }
        sentence += others.isEmpty
            ? "; no other part of the screen scored above \(percent(noteScore))"
            : "; also high: " + others.joined(separator: ", ")

        if let raw = raw, raw.count == scores.count {
            let setAside = scores.indices.filter { raw[$0] != scores[$0] }
                .map { "\(regionName(ofTile: $0, count: scores.count)) \(percent(raw[$0]))" }
            if !setAside.isEmpty {
                sentence += "; set aside because the finer tiles inside did not agree: " + setAside.joined(separator: ", ")
            }
        }
        return sentence
    }

    /// What happened to a high score that did not close anything.
    public enum NearMiss: String, Equatable {
        case recheck       // above the repeat bar: the next scan decides
        case belowBar      // a middling score, left alone
        case heldBack      // a coarse hit set aside because the finer tiles did not agree
    }

    /// Why a high score did not close anything, in one sentence.
    public static func nearMissExplanation(scores: [Double], strict: Bool, kind: NearMiss, raw: [Double]? = nil) -> String {
        guard let top = scores.max(), let index = scores.firstIndex(of: top) else { return "no scores" }
        let region = regionName(ofTile: index, count: scores.count)
        let suspect = strict ? searchSuspectScore : suspectScore
        switch kind {
        case .recheck:
            return "\(region) scored \(percent(top)) explicit, above the \(percent(suspect)) bar for a repeat sighting; the tab closes only if the next scan scores that high again."
        case .belowBar:
            let onSearch = strict ? " that applies on a search-results page" : ""
            return "\(region) scored \(percent(top)) explicit, under the \(percent(suspect)) bar\(onSearch), so nothing was closed."
        case .heldBack:
            var held = ""
            if let raw = raw, raw.count == scores.count {
                let names = scores.indices.filter { raw[$0] != scores[$0] }
                    .map { "\(regionName(ofTile: $0, count: scores.count)) \(percent(raw[$0]))" }
                held = names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"
            }
            return "A high score\(held) was set aside because none of the finer tiles inside it agreed; nothing was closed."
        }
    }

    /// Labels from a general-purpose picture classifier, as `person 93%, swimwear 41%`: the strongest few that
    /// are at least `minimum` likely. Empty when none qualify.
    public static func describeLabels(_ labels: [(name: String, confidence: Double)], minimum: Double = 0.15, limit: Int = 6) -> String {
        labels
            .filter { $0.confidence >= minimum }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.name < $1.name }
            .prefix(limit)
            .map { "\($0.name) \(percent($0.confidence))" }
            .joined(separator: ", ")
    }

    // MARK: - Search results pages

    /// True for a search engine's page (Google, Bing, DuckDuckGo and similar), where the screen is a grid of
    /// result thumbnails.
    public static func isSearchResultsPage(_ urlOrHost: String) -> Bool {
        guard let host = AdultSiteMatcher.host(from: urlOrHost) else { return false }
        if host == "search.yahoo.com" || host == "search.brave.com" { return true }
        let engines: Set<String> = ["google", "bing", "duckduckgo", "ecosia", "startpage", "yandex", "baidu"]
        return host.split(separator: ".").contains { engines.contains(String($0)) }
    }

    // MARK: - Pacing

    /// Seconds until the next look at the screen: 1.5 while it is changing, then 3, then 6 as it stays
    /// still, and doubled (up to 12) in Low Power Mode.
    public static func interval(unchangedScans: Int, lowPower: Bool) -> Double {
        let base: Double
        switch unchangedScans {
        case ..<5: base = 1.5
        case 5..<20: base = 3.0
        default: base = 6.0
        }
        return lowPower ? min(base * 2, 12) : base
    }

    // MARK: - Apps that are never scanned

    /// Terminals and code editors show a lot of changing text and no pictures worth the battery. Video and
    /// music players show film and TV frames, which image models often mistake for explicit pictures.
    public static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.apple.QuickTimePlayerX", "com.apple.TV", "com.apple.Music", "org.videolan.vlc",
        "com.colliderli.iina", "com.spotify.client"
    ]
}
