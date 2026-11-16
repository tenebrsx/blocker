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
