/// Everyday websites that Word Blocker's two "judgement call" checks leave alone: the page-text scan and the
/// screen image scanner. Both can misjudge a normal page (a YouTube comment section full of slang, a
/// swimwear listing, an anatomy article, a movie still), and the user only wants real adult sites blocked.
///
/// This never excuses an adult site: the domain lists and search rules still run first, and a host that
/// those flag is never trusted. Search engines are deliberately NOT in the list, so image results (Google
/// Images, Bing, DuckDuckGo) are still watched.
/// Pure Swift (no Foundation) for easy testing.
public enum TrustedSites {

    /// A host matches an entry if it is that domain or any subdomain of it (`www.youtube.com` matches
    /// `youtube.com`). Entries with a subdomain (`docs.google.com`) trust only that part of a big site.
    static let hosts: [String] = [
        // Video and music
        "youtube.com", "youtu.be", "youtube-nocookie.com", "netflix.com", "disneyplus.com", "hulu.com",
        "primevideo.com", "max.com", "hbomax.com", "peacocktv.com", "paramountplus.com", "crunchyroll.com",
        "twitch.tv", "vimeo.com", "spotify.com", "soundcloud.com", "music.apple.com", "tv.apple.com",
        // Reference, learning, health
        "wikipedia.org", "wikimedia.org", "wiktionary.org", "britannica.com", "khanacademy.org",
        "coursera.org", "udemy.com", "edx.org", "mayoclinic.org", "webmd.com", "nih.gov", "cdc.gov",
        // Work, code and accounts
        "github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com", "linkedin.com", "notion.so",
        "figma.com", "canva.com", "dropbox.com", "slack.com", "zoom.us", "ycombinator.com",
        "apple.com", "icloud.com", "microsoft.com", "office.com", "live.com", "outlook.com",
        "docs.google.com", "drive.google.com", "mail.google.com", "calendar.google.com",
        "meet.google.com", "maps.google.com", "accounts.google.com", "classroom.google.com",
        "translate.google.com",
        // Shopping (product photos of swimwear and lingerie fool image models)
        "amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.es", "amazon.it",
        "amazon.com.au", "amazon.in", "ebay.com", "etsy.com", "walmart.com", "target.com", "bestbuy.com",
        "aliexpress.com", "costco.com", "ikea.com", "zalando.com",
        // News, sport and film
        "nytimes.com", "bbc.com", "bbc.co.uk", "cnn.com", "theguardian.com", "washingtonpost.com",
        "reuters.com", "apnews.com", "espn.com", "imdb.com", "medium.com", "quora.com", "steampowered.com"
    ]

    /// True if the page is on an everyday site that should never be closed or blacked out on a judgement
    /// call. Needs a URL or host; anything unreadable is not trusted.
    public static func isTrusted(urlOrHost: String) -> Bool {
        guard let host = AdultSiteMatcher.host(from: urlOrHost) else { return false }
        if AdultSiteMatcher.isAdult(urlOrHost: urlOrHost) || AdultSiteMatcher.isAdultSearch(urlOrHost: urlOrHost) {
            return false
        }
        for entry in hosts where host == entry || host.hasSuffix("." + entry) { return true }
        return false
    }
}
