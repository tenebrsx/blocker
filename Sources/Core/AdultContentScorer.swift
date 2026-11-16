/// Scores the visible text of a web page for adult content. This is the safety net for adult pages on
/// sites no blocklist knows about: titles, headings, link text and image descriptions on such pages are full
/// of explicit words, and they usually sit behind an "are you 18?" gate.
///
/// It is deliberately hard to trip: a page needs a high score AND several different explicit terms, so a
/// news story, a comment section or a health article that uses a few risqué words is left alone. (Everyday
/// sites such as YouTube are skipped entirely; see `TrustedSites`.)
/// Pure Swift (no Foundation) for easy testing.
public enum AdultContentScorer {

    /// A page scoring at least this much, from enough different terms, is treated as adult content.
    public static let threshold = 18

    /// How many different explicit terms a page needs (a warning phrase counts as two).
    public static let minimumDistinctTerms = 4

    /// An explicit word counts at most this many times, so one repeated word can't trip it alone.
    static let maxCountPerTerm = 2

    /// Exact words and how much each is worth per occurrence.
    static let wordWeights: [String: Int] = [
        "xxx": 3, "hentai": 3, "blowjob": 3, "handjob": 3, "cumshot": 3, "creampie": 3, "gangbang": 3,
        "pussy": 3, "orgy": 3, "bdsm": 3, "milf": 3, "nude": 3, "nudes": 3, "naked": 3, "nsfw": 3,
        "onlyfans": 3, "camgirl": 3, "camgirls": 3, "pornstar": 3, "pornstars": 3,
        "erotic": 2, "erotica": 2, "topless": 2, "boobs": 2, "tits": 2, "anal": 2, "slut": 2, "whore": 2,
        "fetish": 2, "horny": 2, "orgasm": 2, "masturbation": 2, "stripper": 2, "hardcore": 1,
        "sex": 1, "sexy": 1, "sexual": 1,
        // Explicit terms that mostly turn up around male-oriented adult content. Only words that are not also
        // everyday words: `cock`, `dick`, `cum`, `fuck` and friends are left out on purpose, because feeds and
        // comment threads are full of them and a page of ordinary posts must never add up to adult content
        // (adding them closed the Reddit home page several times in two minutes).
        "twink": 3, "twinks": 3, "bareback": 3, "barebacking": 3, "bussy": 3, "cocksucker": 3, "cocksucking": 3,
        "jerkoff": 3, "dickpic": 3, "dickpics": 3, "cumshots": 3, "blowjobs": 3, "handjobs": 3, "bukkake": 3,
        "deepthroat": 3, "gaysex": 3, "dildo": 2, "dildos": 2,
        // Drawn porn, straight and gay.
        "futanari": 3, "paizuri": 3, "ahegao": 3, "lolicon": 3, "shotacon": 3, "rule34": 3, "oppai": 2, "yaoi": 2,
        "ecchi": 1, "doujinshi": 1
    ]

    /// Words starting with these count too (`pornography`, `pornographic`, `pornhub`).
    static let wordPrefixes: [(prefix: String, weight: Int)] = [("porn", 3)]

    /// Age-gate and warning phrases typical of adult sites. Each counts once.
    static let phrases: [(text: String, weight: Int)] = [
        ("adult content", 6), ("explicit content", 6), ("sexually explicit", 6), ("contains nudity", 6),
        ("must be 18", 6), ("18 years of age or older", 6), ("18 years or older", 6), ("over 18 years", 6),
        ("are you 18", 6), ("18+ only", 6), ("adults only", 4), ("mature content", 3), ("18+ content", 6)
    ]

    /// The page's score, how many different explicit terms made it up, and the biggest contributors
    /// (`term x count`, most points first) so a block can be explained afterwards.
    static func analyse(_ text: String) -> (score: Int, distinct: Int, terms: [String]) {
        // Long pages are cut off: the top of the page is where titles and age gates live.
        let lowered = String(text.prefix(20_000)).lowercased()
        var total = 0
        var distinct = 0
        var contributions: [(name: String, points: Int)] = []

        for (phrase, weight) in phrases where lowered.contains(phrase) {
            total += weight
            distinct += 2
            contributions.append(("\"\(phrase)\"", weight))
        }

        var counts: [String: Int] = [:]
        var word = ""
        func finishWord() {
            guard !word.isEmpty else { return }
            if wordWeights[word] != nil {
                counts[word, default: 0] += 1
            } else {
                for entry in wordPrefixes where word.hasPrefix(entry.prefix) {
                    counts[entry.prefix, default: 0] += 1
                    break
                }
            }
            word = ""
        }
        for character in lowered {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                finishWord()
            }
        }
        finishWord()

        for (term, count) in counts {
            let weight = wordWeights[term] ?? wordPrefixes.first(where: { $0.prefix == term })?.weight ?? 0
            total += weight * min(count, maxCountPerTerm)
            distinct += 1
            contributions.append(("\(term)x\(min(count, maxCountPerTerm))", weight * min(count, maxCountPerTerm)))
        }
        let terms = contributions.sorted { $0.points != $1.points ? $0.points > $1.points : $0.name < $1.name }
            .prefix(8).map { $0.name }
        return (total, distinct, Array(terms))
    }

    public static func score(_ text: String) -> Int {
        analyse(text).score
    }

    public static func isAdultContent(_ text: String) -> Bool {
        let result = analyse(text)
        return result.score >= threshold && result.distinct >= minimumDistinctTerms
    }
}
