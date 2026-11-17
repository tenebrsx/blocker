/// Built-in, always-on detection of adult websites.
///
/// Unlike the user's blocked-websites list there is no "Allow" path here: no temporary allowance, no math
/// unlock, no setting that turns it off. It is compiled in, so it also can't be removed from Settings.
/// Pure Swift (no Foundation) so it can be unit-tested anywhere.
public enum AdultSiteMatcher {

    /// Extra lookup against the large downloaded blocklists (`AdultDomainList`). Set at startup so this file
    /// stays free of Foundation and easy to test.
    public static var domainLookup: ((String) -> Bool)?

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
        "redgifs", "camgirl", "gaysex", "gaycam", "gaytube", "cocksuck", "dickpic",
        "yaoi", "futanari", "paizuri", "ahegao"
    ]

    /// Whole words inside a hyphen-separated label (`sex-videos`, `nsfw-pics`), so they can't match
    /// the middle of an unrelated word (`analytics`, `peacock`, `essex`).
    static let labelTokens: Set<String> = [
        "sex", "sexy", "nsfw", "nude", "nudes", "naked", "topless", "milf", "erotic", "erotica", "fetish",
        "anal", "tits", "boobs", "slut", "sluts", "whore", "orgy", "jav", "fap", "escorts",
        "twink", "twinks", "bareback", "barebacking", "bussy"
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
        "nudist", "cum", "cumming", "cums", "thot", "thots", "bukkake", "deepthroat", "footjob", "rimjob",
        "squirt", "squirting", "lewd", "lewds", "ahegao", "jizz", "wank", "wanking", "incest", "pron",
        "loli", "lolicon", "shotacon", "jailbait", "sexo", "desnuda", "desnudas", "desnudo",
        // Explicit terms that mostly turn up around male-oriented adult content. Single words that are also
        // ordinary words (cock, dick, hung) are only blocked inside the phrases below.
        "twink", "twinks", "bareback", "barebacking", "bussy", "dickpic", "dickpics", "cocksucker", "cocksuckers",
        "cocksucking", "jerkoff", "gaysex", "gaycam", "gaycams", "dildo", "dildos",
        // Drawn porn, straight and gay (`yaoi` is gay manga, mostly explicit in the West).
        "yaoi", "futanari", "paizuri", "oppai"
    ]

    /// Word sequences that block a search, for terms that are fine on their own (`cock`, `dick`, `jerk`).
    /// Matched against whole words in order, so `big cockatoo` and `hard dickens` are not caught.
    static let queryPhrases: [String] = [
        "jerk off", "jerking off", "dick pic", "dick pics", "big dick", "big cock", "hard dick", "hard cock",
        "suck dick", "suck cock", "sucking dick", "sucking cock", "gay cam", "gay cams", "gay webcam",
        "hung guys", "hung men", "hung twink", "hung twinks", "rule 34"
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

    /// Why something was judged adult: which rule fired, the list entry that matched, and a plain-English
    /// sentence for the block log. `matched` is always an entry of one of this file's lists (or the site's own
    /// address), never the visitor's search words, so a record of it does not keep what was searched.
    public struct MatchReason: Equatable {
        public let rule: String
        public let matched: String
        public let detail: String

        public init(rule: String, matched: String, detail: String) {
            self.rule = rule
            self.matched = matched
            self.detail = detail
        }
    }

    /// Why the address itself is an adult site, or nil when it is not.
    public static func adultSiteReason(urlOrHost: String) -> MatchReason? {
        guard let host = host(from: urlOrHost) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard let tld = labels.last else { return nil }

        if adultTLDs.contains(tld) {
            return MatchReason(rule: "adult-tld", matched: "." + tld,
                               detail: "The address ends in “.\(tld)”, a domain ending used only for adult sites.")
        }

        // Known domain: check every suffix (a.b.pornhub.com -> b.pornhub.com -> pornhub.com).
        for start in 0..<labels.count {
            let candidate = labels[start...].joined(separator: ".")
            if knownDomains.contains(candidate) {
                return MatchReason(rule: "known-domain", matched: candidate,
                                   detail: "The site (\(candidate)) is on the built-in list of adult sites.")
            }
        }

        // The big downloaded lists (about a million domains).
        if let lookup = domainLookup, lookup(host) {
            return MatchReason(rule: "blocklist", matched: host,
                               detail: "The site (\(host)) is on one of the downloaded adult-site blocklists (StevenBlack, Blocklist Project).")
        }

        // Keyword heuristics on every label except the TLD.
        for label in labels.dropLast() {
            for fragment in labelSubstrings where label.contains(fragment) {
                return MatchReason(rule: "domain-keyword", matched: fragment,
                                   detail: "The site name contains “\(fragment)”, which does not turn up in ordinary site names.")
            }
            for token in label.split(separator: "-") where labelTokens.contains(String(token)) {
                return MatchReason(rule: "domain-word", matched: String(token),
                                   detail: "The site name has the word “\(token)” in it, between hyphens.")
            }
        }
        return nil
    }

    /// True when the address itself is an adult site.
    public static func isAdult(urlOrHost: String) -> Bool {
        adultSiteReason(urlOrHost: urlOrHost) != nil
    }

    /// Why the URL is a search (on any site) for adult content, e.g. `google.com/search?q=porn`, or nil.
    public static func adultSearchReason(urlOrHost: String) -> MatchReason? {
        let lowered = Substring(trimmed(urlOrHost).lowercased())
        guard !lowered.isEmpty, let text = withoutScheme(lowered) else { return nil }
        guard let questionMark = text.firstIndex(of: "?") else { return nil }

        var query = text[text.index(after: questionMark)...]
        if let hash = query.firstIndex(of: "#") { query = query[query.startIndex..<hash] }

        for pair in query.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<equals])
            guard queryParameters.contains(name) else { continue }
            if let reason = adultTermReason(percentDecoded(pair[pair.index(after: equals)...])) { return reason }
        }
        return nil
    }

    /// True when the URL is a search (on any site) for adult content, e.g. `google.com/search?q=porn`.
    public static func isAdultSearch(urlOrHost: String) -> Bool {
        adultSearchReason(urlOrHost: urlOrHost) != nil
    }

    // MARK: - Reddit communities and post titles

    /// Fragments of a community name (`r/<name>`) that mark an adult community, so `r/SomethingPorn` and
    /// `r/gonewild30plus` are caught without the page ever being judged by a model.
    static let communityFragments: [String] = [
        "porn", "xxx", "hentai", "nsfw", "gonewild", "rule34", "onlyfans", "nudes", "bareback", "twink",
        "blowjob", "creampie", "cumshot", "gangbang", "bdsm", "bukkake", "deepthroat", "camgirl", "cocksuck",
        "realgirls",
        // Drawn and animated porn, straight and gay: hentai itself is covered by the first list above.
        "yaoi", "ecchi", "doujinshi", "ahegao", "futanari", "paizuri", "oppai", "lewd", "lolicon", "shotacon"
    ]

    /// Recovery and support communities that have those words in their names. Never blocked.
    static let recoveryCommunities: [String] = [
        "nofap", "pornfree", "pornaddiction", "pornrecovery", "stopporn", "quitporn", "antiporn", "fapstronaut"
    ]

    /// Whole words in a post's title (Reddit puts it in the address as `.../comments/<id>/<title_slug>`) that
    /// mean the post is explicit media. Discussion words (`porn`, `sex`, `fuck`) are left out on purpose: they
    /// turn up in advice threads and swearing, which are not adult content.
    static let postTitleWords: Set<String> = [
        "xxx", "hentai", "nsfw", "blowjob", "blowjobs", "handjob", "handjobs", "cumshot", "cumshots", "creampie",
        "gangbang", "twink", "twinks", "bareback", "barebacking", "bukkake", "deepthroat", "onlyfans", "gonewild",
        "nudes", "milf", "dildo", "dildos", "bussy", "cocksucker", "cocksucking", "pornstar", "pornstars",
        "ahegao", "futanari", "paizuri", "lolicon", "shotacon", "rule34"
    ]

    /// Why a Reddit page counts as an adult community (or a post titled as explicit media), or nil.
    public static func adultCommunityReason(urlOrHost: String) -> MatchReason? {
        guard let host = host(from: urlOrHost), host == "reddit.com" || host.hasSuffix(".reddit.com") else { return nil }
        let lowered = Substring(trimmed(urlOrHost).lowercased())
        guard let text = withoutScheme(lowered), let slash = text.firstIndex(of: "/") else { return nil }
        var path = text[slash...]
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[path.startIndex..<cut] }

        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "r" else { return nil }

        let community = segments[1]
        if recoveryCommunities.contains(where: { community.contains($0) }) { return nil }
        if let fragment = communityFragments.first(where: { community.contains($0) }) {
            return MatchReason(rule: "community-name", matched: fragment,
                               detail: "The community name (r/\(community)) contains “\(fragment)”, which marks an adult community.")
        }

        // /r/<community>/comments/<id>/<title_slug>
        guard segments.count >= 5, segments[2] == "comments" else { return nil }
        var word = ""
        var words: [String] = []
        for character in segments[4] {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        if let hit = words.first(where: { postTitleWords.contains($0) }) {
            return MatchReason(rule: "post-title", matched: hit,
                               detail: "The post’s title (it is in the address) contains the word “\(hit)”, which means explicit media.")
        }
        return nil
    }

    /// True for a Reddit page in an adult community, or for a post whose title says it is explicit media.
    public static func isAdultCommunityPage(urlOrHost: String) -> Bool {
        adultCommunityReason(urlOrHost: urlOrHost) != nil
    }

    static func containsAdultTerms(_ phrase: String) -> Bool {
        adultTermReason(phrase) != nil
    }

    /// Which explicit phrase, word or word fragment a phrase contains, or nil. The result names the list entry
    /// that matched and how it was spelled (plainly, disguised with digits or stretched letters, or spelled out
    /// letter by letter), not the words that were typed.
    static func adultTermReason(_ phrase: String) -> MatchReason? {
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

        // Spelled out with spaces ("p o r n"): a run of three or more single letters also counts as one word.
        var spelledOut: Set<String> = []
        var run = ""
        var runLength = 0
        for word in words {
            if word.count == 1, word.first?.isLetter == true {
                run += word
                runLength += 1
            } else {
                if runLength >= 3 { words.append(run); spelledOut.insert(run) }
                run = ""
                runLength = 0
            }
        }
        if runLength >= 3 { words.append(run); spelledOut.insert(run) }

        let sentence = " " + words.joined(separator: " ") + " "
        for phrase in queryPhrases where sentence.contains(" " + phrase + " ") {
            return MatchReason(rule: "search-phrase", matched: phrase,
                               detail: "The search contains the phrase “\(phrase)”, which is on the explicit-phrase list.")
        }

        for word in words {
            for candidate in spellingVariants(of: word) {
                let how: String
                if spelledOut.contains(word) {
                    how = ", spelled out letter by letter"
                } else if candidate != word {
                    how = ", in a disguised spelling (digits swapped for letters, or stretched letters)"
                } else {
                    how = ""
                }
                if queryWords.contains(candidate) {
                    return MatchReason(rule: "search-word", matched: candidate,
                                       detail: "The search contains the explicit word “\(candidate)”\(how).")
                }
                for fragment in queryFragments where candidate.contains(fragment) {
                    return MatchReason(rule: "search-fragment", matched: fragment,
                                       detail: "The search has a word that contains “\(fragment)”\(how), which only turns up in explicit terms.")
                }
            }
        }
        return nil
    }

    /// The word itself, plus versions with common disguises undone: digits swapped for letters
    /// (`p0rn`, `s3x`) and stretched letters squeezed (`pooorn`, `sexxx`).
    static func spellingVariants(of word: String) -> [String] {
        var variants = [word]

        let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t"]
        if word.contains(where: { $0.isLetter }), word.contains(where: { leet[$0] != nil }) {
            variants.append(String(word.map { leet[$0] ?? $0 }))
        }

        // A letter repeated three or more times in a row becomes a single letter.
        var squeezed = ""
        var changed = false
        let characters = Array(word)
        var index = 0
        while index < characters.count {
            var end = index
            while end < characters.count && characters[end] == characters[index] { end += 1 }
            let runLength = end - index
            if runLength >= 3 {
                squeezed.append(characters[index])
                changed = true
            } else {
                for _ in 0..<runLength { squeezed.append(characters[index]) }
            }
            index = end
        }
        if changed { variants.append(squeezed) }
        return variants
    }

    /// Fallback for when a browser hides its address: a page title that names an adult site or category.
    public static func adultTitleReason(_ title: String) -> MatchReason? {
        let lowered = title.lowercased()
        for fragment in titleFragments where lowered.contains(fragment) {
            return MatchReason(rule: "title-keyword", matched: fragment,
                               detail: "The browser did not show the page address, and the page title contains “\(fragment)”.")
        }
        return nil
    }

    public static func isAdultTitle(_ title: String) -> Bool {
        adultTitleReason(title) != nil
    }
}
