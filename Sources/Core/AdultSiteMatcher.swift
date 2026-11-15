/// Built-in, always-on detection of adult websites.
///
/// Unlike the user's blocked-websites list there is no "Allow" path here: no temporary allowance, no math
/// unlock, no setting that turns it off. It is compiled in, so it also can't be removed from Settings.
/// Pure Swift (no Foundation) so it can be unit-tested anywhere.
public enum AdultSiteMatcher {

    // MARK: - Site address rules

    /// Top-level domains that exist for adult content.
    static let adultTLDs: Set<String> = ["xxx", "porn", "adult", "sex", "sexy"]

    /// A hostname label containing any of these is treated as adult (e.g. `pornhub`, `free-xxx-videos`).
    /// Only strings that are not part of ordinary words, so `essex.ac.uk` and `sussex.org` are safe.
    static let labelSubstrings: [String] = [
        "porn", "xxx", "hentai", "xvideos", "xnxx", "xhamster", "redtube", "youporn", "onlyfans",
        "chaturbate", "stripchat", "bongacams", "livejasmin", "brazzers", "rule34", "camwhores",
        "pussy", "fuck", "blowjob", "cumshot", "gangbang", "creampie", "bdsm", "nudist",
        "sexvid", "sexcam", "sexchat", "sextube", "sexmov", "sexpic", "sexstor", "freesex", "livesex",
        "redgifs", "camgirl"
    ]

    /// Whole words inside a hyphen-separated label (`sex-videos`, `nsfw-pics`), so they can't match
    /// the middle of an unrelated word (`analytics`, `peacock`, `essex`).
    static let labelTokens: Set<String> = [
        "sex", "sexy", "nsfw", "nude", "nudes", "naked", "topless", "milf", "erotic", "erotica", "fetish",
        "anal", "tits", "boobs", "slut", "sluts", "whore", "orgy", "jav", "fap", "escorts"
    ]

    /// Well-known adult sites whose names don't give them away. A domain here also blocks every subdomain.
    static let knownDomains: Set<String> = [
        "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "redtube.com", "youporn.com", "tube8.com",
        "spankbang.com", "eporner.com", "tnaflix.com", "motherless.com", "thumbzilla.com", "beeg.com",
        "txxx.com", "hclips.com", "hqporner.com", "daftsex.com", "sunporno.com", "drtuber.com", "4tube.com",
        "pornone.com", "porntrex.com", "vporn.com", "xgroovy.com", "nonktube.com", "ixxx.com", "fapality.com",
        "pichunter.com", "pornpics.com", "fuq.com", "sex.com", "nudevista.com", "ashemaletube.com",
        "fapello.com", "erome.com", "thothub.to", "coomer.su", "simpcity.su", "recurbate.com",
        "hotmovs.com", "upornia.com", "tubegalore.com", "xozilla.com", "nuvid.com", "xxnx.com",
        "slutload.com", "sxyprn.com", "analdin.com", "efukt.com", "eroprofile.com", "imagefap.com",
        "scrolller.com", "redgifs.com", "sexstories.com",
        "nhentai.net", "hanime.tv", "e-hentai.org", "gelbooru.com", "luscious.net", "fakku.net",
        "tsumino.com", "hitomi.la", "e621.net",
        "missav.com", "supjav.com", "jable.tv", "javbus.com", "javlibrary.com", "123av.com", "njav.tv",
        "onlyfans.com", "fansly.com", "manyvids.com", "clips4sale.com", "iwantclips.com",
        "chaturbate.com", "stripchat.com", "bongacams.com", "livejasmin.com", "cam4.com", "myfreecams.com",
        "camsoda.com", "flirt4free.com", "streamate.com", "jerkmate.com", "imlive.com",
        "brazzers.com", "realitykings.com", "bangbros.com", "naughtyamerica.com", "mofos.com", "nubiles.net",
        "kink.com", "adulttime.com", "teamskeet.com", "vixen.com", "blacked.com", "tushy.com", "deeper.com",
        "digitalplayground.com", "evilangel.com", "julesjordan.com", "metart.com", "xart.com",
        "playboy.com", "penthouse.com", "hustler.com",
        "bellesa.co", "literotica.com", "adultfriendfinder.com"
    ]

    // MARK: - Search query rules

    /// Words that block a search outright. Whole words only.
    static let queryWords: Set<String> = [
        "sex", "sexy", "sexting", "nsfw", "nude", "nudes", "naked", "topless", "milf", "erotic", "erotica",
        "fetish", "camgirl", "camgirls", "blowjob", "handjob", "cumshot", "creampie", "gangbang", "bdsm",
        "pussy", "anal", "tits", "boobs", "slut", "whore", "orgy", "jav", "fap", "onlyfans", "redgifs",
        "nudist"
    ]

    /// Any word that merely contains one of these (`pornstar`, `xxxvideos`) also blocks a search.
    static let queryFragments: [String] = ["porn", "xxx", "hentai", "xvideos", "xnxx", "xhamster", "rule34"]

    /// Query-string parameters that hold what the user searched for.
    static let queryParameters: Set<String> = [
        "q", "query", "search_query", "search", "p", "text", "k", "wd", "keyword", "keywords", "s", "term"
    ]

    // MARK: - Page title rules (only used when a browser won't reveal the address)

    static let titleFragments: [String] = [
        "porn", "xxx", "hentai", "xvideos", "xnxx", "xhamster", "onlyfans", "redtube", "youporn",
        "brazzers", "chaturbate", "stripchat", "rule34", "nsfw"
    ]

    // MARK: - Parsing

    private static func trimmed(_ value: String) -> Substring {
        var text = Substring(value)
        while let first = text.first, first == " " || first == "\n" || first == "\t" { text.removeFirst() }
        while let last = text.last, last == " " || last == "\n" || last == "\t" { text.removeLast() }
        return text
    }

    /// The part of a URL after `scheme://`, or the text itself when there is no scheme.
    /// Returns nil for internal pages (`about:`, `chrome://`, ...).
    private static func withoutScheme(_ lowercased: Substring) -> Substring? {
        if let range = lowercased.firstRange(of: "://") {
            let scheme = lowercased[lowercased.startIndex..<range.lowerBound]
            guard scheme == "http" || scheme == "https" || scheme == "ftp" else { return nil }
            return lowercased[range.upperBound...]
        }
        for internalScheme in ["about:", "javascript:", "data:", "file:", "view-source:", "blob:"]
        where lowercased.hasPrefix(internalScheme) { return nil }
        return lowercased
    }

    /// Hostname for a URL or bare host as read from a browser; nil for internal pages, search text, etc.
    public static func host(from urlOrHost: String) -> String? {
        let lowered = Substring(trimmed(urlOrHost).lowercased())
        guard !lowered.isEmpty, var text = withoutScheme(lowered) else { return nil }

        if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = text[text.startIndex..<end]
        }
        if let at = text.lastIndex(of: "@") { text = text[text.index(after: at)...] }
        if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy({ $0.isNumber }) {
            text = text[text.startIndex..<colon]
        }
        while text.hasSuffix(".") { text.removeLast() }

        guard !text.isEmpty, !text.contains(" ") else { return nil }
        return String(text)
    }

    /// Decodes `%XX` escapes (as UTF-8) and `+` as space, the way a query string is written.
    static func percentDecoded(_ text: Substring) -> String {
        var bytes: [UInt8] = []
        let chars = Array(text.utf8)
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            case 65...70: return byte - 55
            default: return nil
            }
        }
        while index < chars.count {
            let byte = chars[index]
            if byte == UInt8(ascii: "%"), index + 2 < chars.count,
               let high = hexValue(chars[index + 1]), let low = hexValue(chars[index + 2]) {
                bytes.append(high * 16 + low)
                index += 3
            } else if byte == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
                index += 1
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Checks

    /// True when the address itself is an adult site.
    public static func isAdult(urlOrHost: String) -> Bool {
        guard let host = host(from: urlOrHost) else { return false }
        let labels = host.split(separator: ".").map(String.init)
        guard let tld = labels.last else { return false }

        if adultTLDs.contains(tld) { return true }

        // Known domain: check every suffix (a.b.pornhub.com -> b.pornhub.com -> pornhub.com).
        for start in 0..<labels.count where knownDomains.contains(labels[start...].joined(separator: ".")) {
            return true
        }

        // Keyword heuristics on every label except the TLD.
        for label in labels.dropLast() {
            for fragment in labelSubstrings where label.contains(fragment) { return true }
            for token in label.split(separator: "-") where labelTokens.contains(String(token)) { return true }
        }
        return false
    }

    /// True when the URL is a search (on any site) for adult content, e.g. `google.com/search?q=porn`.
    public static func isAdultSearch(urlOrHost: String) -> Bool {
        let lowered = Substring(trimmed(urlOrHost).lowercased())
        guard !lowered.isEmpty, let text = withoutScheme(lowered) else { return false }
        guard let questionMark = text.firstIndex(of: "?") else { return false }

        var query = text[text.index(after: questionMark)...]
        if let hash = query.firstIndex(of: "#") { query = query[query.startIndex..<hash] }

        for pair in query.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<equals])
            guard queryParameters.contains(name) else { continue }
            if containsAdultTerms(percentDecoded(pair[pair.index(after: equals)...])) { return true }
        }
        return false
    }

    static func containsAdultTerms(_ phrase: String) -> Bool {
        var word = ""
        var words: [String] = []
        for character in phrase.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }

        for word in words {
            if queryWords.contains(word) { return true }
            for fragment in queryFragments where word.contains(fragment) { return true }
        }
        return false
    }

    /// Fallback for when a browser hides its address: a page title that names an adult site or category.
    public static func isAdultTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        for fragment in titleFragments where lowered.contains(fragment) { return true }
        return false
    }
}
