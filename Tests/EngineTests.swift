import Foundation

@main
struct TestRunner {
    static func assertTest(_ condition: Bool, _ message: String) {
        if !condition {
            print("❌ FAILED: \(message)")
            exit(1)
        } else {
            print("✅ PASSED: \(message)")
        }
    }

    static func main() {
        print("=== Running Word Blocker Engine, Obfuscation & Exceptions Tests ===")

        let store = WordStore.shared
        store.clearAllWords()
        store.clearAllExceptions()

        _ = store.addWord("bad")
        _ = store.addWord("word")
        _ = store.addWord("secret")
        _ = store.addWord("forbidden")

        _ = store.addException("badger")
        _ = store.addException("badge")
        _ = store.addException("password")
        _ = store.addException("compass")

        store.isFuzzyEnabled = true

        let engine = WordBufferEngine.shared
        engine.reset()

        // -------------------------------------------------------------
        // Test 1: Standard Exact Word Matching
        // -------------------------------------------------------------
        print("\n--- Test 1: Standard Exact Matching ---")
        let exactRes = engine.processInput("word")
        assertTest(exactRes != nil, "Matches exact word 'word'")
        assertTest(exactRes?.matchedWord == "word", "Matched word is 'word'")
        assertTest(exactRes?.deleteCount == 4, "Delete count is 4 for 'word'")

        // -------------------------------------------------------------
        // Test 2: Character Elongation & Leetspeak
        // -------------------------------------------------------------
        print("\n--- Test 2: Character Elongation & Leetspeak ---")
        engine.reset()
        let wordRes = engine.processInput("w0000000rrrrrd")
        assertTest(wordRes != nil, "Detected 'w0000000rrrrrd' as variation of 'word'")
        assertTest(wordRes?.deleteCount == 14, "Physical delete count is 14 for 'w0000000rrrrrd'")

        // -------------------------------------------------------------
        // Test 3: Exception Protection (Allowed Words)
        // -------------------------------------------------------------
        print("\n--- Test 3: Exceptions / Whitelist Protection ---")
        engine.reset()

        // Typing exception word "password" (which contains "pass")
        let exRes1 = engine.processInput("password")
        assertTest(exRes1 == nil, "Exception 'password' was NOT blocked")

        // Typing exception word "badge"
        engine.reset()
        let exRes2 = engine.processInput("badge")
        assertTest(exRes2 == nil, "Exception 'badge' was NOT blocked")

        // Typing exception word "badger" character-by-character
        engine.reset()
        _ = engine.processInput("b")
        _ = engine.processInput("a")
        let badPrefix = engine.processInput("d") // 'bad' is typed, but 'badger' is in exceptions!
        assertTest(badPrefix == nil, "'bad' prefix deferred because 'badger' is an allowed exception")

        _ = engine.processInput("g")
        _ = engine.processInput("e")
        let badgerComplete = engine.processInput("r")
        assertTest(badgerComplete == nil, "Completed exception 'badger' was NOT blocked")

        // Typing 'bad ' followed by a space (so user was NOT typing badger, but actually bad)
        engine.reset()
        _ = engine.processInput("bad")
        let badWithSpace = engine.processInput(" ")
        assertTest(badWithSpace != nil, "'bad ' followed by word boundary IS blocked")

        // -------------------------------------------------------------
        // Test 4: Infix Noise & Punctuation Padding
        // -------------------------------------------------------------
        print("\n--- Test 4: Infix Noise & Punctuation Padding ---")
        engine.reset()
        let noiseRes = engine.processInput("w.o.r.d")
        assertTest(noiseRes != nil, "Detected 'w.o.r.d' as variation of 'word'")
        assertTest(noiseRes?.deleteCount == 7, "Physical delete count is 7 for 'w.o.r.d'")

        // -------------------------------------------------------------
        // Test 5: Typo & Transposition (Fuzzy Distance)
        // -------------------------------------------------------------
        print("\n--- Test 5: Typos & Transpositions ---")
        engine.reset()
        let transRes = engine.processInput("sceret")
        assertTest(transRes != nil, "Detected adjacent transposition 'sceret' for 'secret'")

        // -------------------------------------------------------------
        // Test 7: Pop-Up Notes Management & Resolution
        // -------------------------------------------------------------
        print("\n--- Test 7: Pop-Up Notes Operations ---")
        _ = store.addWord("sloth", note: "Stay disciplined and focus on your goals!")
        assertTest(store.getNote(for: "sloth") == "Stay disciplined and focus on your goals!", "Note saved for 'sloth'")

        engine.reset()
        let noteMatch = engine.processInput("sloth")
        assertTest(noteMatch != nil, "Matched 'sloth'")
        assertTest(noteMatch?.note == "Stay disciplined and focus on your goals!", "Match includes assigned custom note")

        // Update note
        store.setNote(for: "sloth", note: "Updated custom reminder")
        assertTest(store.getNote(for: "sloth") == "Updated custom reminder", "Updated note for 'sloth'")

        // Word without note
        engine.reset()
        let noNoteMatch = engine.processInput("word")
        assertTest(noNoteMatch != nil, "Matched 'word'")
        assertTest(noNoteMatch?.note == nil, "Word without note returns nil note")

        // -------------------------------------------------------------
        // Test 8: Custom Intervention Messages (Disable & Quit)
        // -------------------------------------------------------------
        print("\n--- Test 8: Custom Intervention Messages ---")
        assertTest(!store.disableProtectionMessage.isEmpty, "Disable protection message exists")
        assertTest(!store.quitMessage.isEmpty, "Quit message exists")

        store.disableProtectionMessage = "Custom Disable Warning!"
        assertTest(store.disableProtectionMessage == "Custom Disable Warning!", "Updated disable protection message")

        store.quitMessage = "Custom Quit Warning!"
        assertTest(store.quitMessage == "Custom Quit Warning!", "Updated quit message")

        // -------------------------------------------------------------
        // Test 9: Blocked Websites & Website Notes
        // -------------------------------------------------------------
        print("\n--- Test 9: Blocked Websites & Notes Operations ---")
        store.clearAllWebsites()
        _ = store.addWebsite("reddit.com", note: "Stay off Reddit during work!")
        _ = store.addWebsite("youtube.com/shorts", note: "No shorts allowed!")
        _ = store.addWebsite("https://www.twitter.com/", note: "Avoid Twitter!")

        assertTest(store.getWebsites().contains("reddit.com"), "Added 'reddit.com'")
        assertTest(store.getWebsites().contains("twitter.com"), "Normalized and added 'twitter.com'")
        assertTest(store.getWebsites().contains("youtube.com/shorts"), "Added path-specific website")

        assertTest(store.getWebsiteNote(for: "reddit.com") == "Stay off Reddit during work!", "Website note for 'reddit.com'")
        assertTest(store.getWebsiteNote(for: "twitter.com") == "Avoid Twitter!", "Website note for 'twitter.com'")

        // Matching tests
        let redditMatch1 = store.matchBlockedWebsite(urlOrHost: "https://www.reddit.com/r/swift")
        assertTest(redditMatch1 != nil, "Matched https://www.reddit.com/r/swift")
        assertTest(redditMatch1?.matchedDomain == "reddit.com", "Matched domain is reddit.com")
        assertTest(redditMatch1?.note == "Stay off Reddit during work!", "Matched note is correct")

        let redditSubdomain = store.matchBlockedWebsite(urlOrHost: "https://old.reddit.com")
        assertTest(redditSubdomain != nil, "Matched subdomain old.reddit.com")

        let falseReddit = store.matchBlockedWebsite(urlOrHost: "https://notreddit.com")
        assertTest(falseReddit == nil, "Did not falsely match notreddit.com")

        let falseRedditSuffix = store.matchBlockedWebsite(urlOrHost: "https://reddit.com.otherdomain.org")
        assertTest(falseRedditSuffix == nil, "Did not falsely match other domain with reddit in host prefix")

        let shortsMatch = store.matchBlockedWebsite(urlOrHost: "https://www.youtube.com/shorts/abc123xyz")
        assertTest(shortsMatch != nil, "Matched specific path youtube.com/shorts")

        let nonShortsMatch = store.matchBlockedWebsite(urlOrHost: "https://www.youtube.com/watch?v=123")
        assertTest(nonShortsMatch == nil, "Did not match non-shorts YouTube URL when only shorts is blocked")

        // Removal
        store.removeWebsite("reddit.com")
        assertTest(!store.getWebsites().contains("reddit.com"), "Removed reddit.com")
        assertTest(store.matchBlockedWebsite(urlOrHost: "https://reddit.com") == nil, "Removed domain is no longer matched")

        // -------------------------------------------------------------
        // Test 10: Access Gate & Temporary Allowance
        // -------------------------------------------------------------
        print("\n--- Test 10: Access Gate & Temporary Allowance ---")
        assertTest(store.requireAllowToEnter == true, "Access Gate enabled by default")
        assertTest(store.requireUnlockWait == true, "The 30-second unlock wait is on by default")
        store.requireUnlockWait = false
        assertTest(store.requireUnlockWait == false, "The unlock wait can be turned off")
        store.requireUnlockWait = true
        assertTest(store.requireUnlockWait == true, "...and back on")
        store.clearTemporaryAllowances()

        assertTest(!store.isWebsiteTemporarilyAllowed("twitter.com"), "Twitter not yet allowed")
        store.allowWebsiteTemporarily("twitter.com", minutes: 10)
        assertTest(store.isWebsiteTemporarilyAllowed("twitter.com"), "Twitter is now temporarily allowed for 10 min")
        assertTest(store.isWebsiteTemporarilyAllowed("mobile.twitter.com"), "Subdomain of Twitter is also temporarily allowed")

        store.clearTemporaryAllowances()
        assertTest(!store.isWebsiteTemporarilyAllowed("twitter.com"), "Temporary allowances successfully cleared")

        // -------------------------------------------------------------
        // Test 11: Cinema Mode Configuration & Messages
        // -------------------------------------------------------------
        print("\n--- Test 11: Cinema Mode Configuration & Messages ---")
        assertTest(!store.cinemaModeMessage.isEmpty, "Cinema mode has a default message")

        var cinemaCallbackFired = false
        store.onCinemaModeChanged = {
            cinemaCallbackFired = true
        }

        store.isCinemaModeEnabled = true
        assertTest(store.isCinemaModeEnabled == true, "Cinema mode successfully enabled")
        assertTest(cinemaCallbackFired == true, "Cinema mode callback fired on toggle")

        let customMsg = "Focus on the movie! Do not tab out."
        store.cinemaModeMessage = customMsg
        assertTest(store.cinemaModeMessage == customMsg, "Cinema mode message updated and saved")

        store.isCinemaModeEnabled = false
        assertTest(store.isCinemaModeEnabled == false, "Cinema mode successfully disabled")

        // -------------------------------------------------------------
        // Test 12: Math Challenge (quit / social unlock friction gate)
        // -------------------------------------------------------------
        print("\n--- Test 12: Math Challenge ---")
        let generated = MathChallenge.generate(count: 2000)
        assertTest(generated.count == 2000, "Generates the requested number of problems")
        assertTest(generated.allSatisfy { $0.answer > 0 }, "Every generated answer is positive")
        assertTest(Set(generated.map { $0.prompt }).count > 500, "Problems vary")
        // Quick mental math: exactly two numbers and one + or −, nothing over two digits (the answer
        // included), and re-evaluating the prompt gives the stored answer.
        var twoNumbersOK = true
        var sawAddition = false, sawSubtraction = false
        for problem in generated {
            let parts = problem.prompt.split(separator: " ").map(String.init)
            guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[2]), parts[1] == "+" || parts[1] == "−" else {
                twoNumbersOK = false; break
            }
            let value = parts[1] == "+" ? a + b : a - b
            if parts[1] == "+" { sawAddition = true } else { sawSubtraction = true }
            if a > 99 || b > 99 || a < 6 || b < 6 || value != problem.answer || value < 5 || value > 99 { twoNumbersOK = false; break }
        }
        assertTest(twoNumbersOK, "Every problem is two numbers (two digits at most) and one + or −, with a 5-99 answer")
        assertTest(sawAddition && sawSubtraction, "Both additions and subtractions appear")
        assertTest(!generated.contains { $0.prompt.contains("×") || $0.prompt.contains("÷") || $0.prompt.contains("(") }, "No multiplication, division or brackets")
        assertTest(MathChallenge.siteUnlockCoolOff(waitEnabled: true) == MathChallenge.coolOffSeconds && MathChallenge.coolOffSeconds == 30, "Site unlock waits 30 seconds by default")
        assertTest(MathChallenge.siteUnlockCoolOff(waitEnabled: false) == 0, "...and not at all when the wait is turned off")
        assertTest(MathChallenge.problemCount(forUnlockNumber: 0) == 5, "First unlock of the day needs 5 problems")
        assertTest(MathChallenge.problemCount(forUnlockNumber: 1) == 7, "Second unlock needs 7")
        assertTest(MathChallenge.problemCount(forUnlockNumber: 2) == 10 && MathChallenge.problemCount(forUnlockNumber: 8) == 10, "Third and later unlocks need 10")
        assertTest(MathChallenge.strictProblemCount == 10, "Quit / loosening needs 10 problems")
        assertTest(MathChallenge.parseAnswer(" 42 ") == 42, "Answer parsing trims whitespace")
        assertTest(MathChallenge.parseAnswer("") == nil && MathChallenge.parseAnswer("4x") == nil, "Empty / non-numeric answers are rejected")

        let session = MathChallengeSession(count: 3, problems: [
            MathProblem(prompt: "a", answer: 1), MathProblem(prompt: "b", answer: 2), MathProblem(prompt: "c", answer: 3)
        ])
        assertTest(session.submit("zzz") == .invalid && session.index == 0, "Invalid input does not count as an answer")
        assertTest(session.submit("1") == .correct(finished: false) && session.index == 1, "Correct answer advances")
        assertTest(session.submit("99") == .wrong && session.index == 0 && session.problems.count == 3, "Wrong answer resets progress and deals new problems")
        let quick = MathChallengeSession(count: 2, problems: [MathProblem(prompt: "a", answer: 1), MathProblem(prompt: "b", answer: 2)])
        _ = quick.submit("1")
        assertTest(quick.submit("2") == .correct(finished: true) && quick.isComplete, "All answers in a row completes the challenge")

        // Unlock counter (feeds the escalation above)
        let unlocksBefore = store.unlocksToday()
        store.recordUnlock()
        assertTest(store.unlocksToday() == unlocksBefore + 1, "Recording an unlock increments today's count")

        // -------------------------------------------------------------
        // Test 13: Built-in adult site hard block
        // -------------------------------------------------------------
        print("\n--- Test 13: Adult Site Matcher ---")
        let adultURLs = [
            "https://www.pornhub.com/view_video.php?viewkey=1", "xvideos.com", "https://a.b.xhamster.com/x",
            "https://example.xxx", "https://free-sex-videos.net/", "https://cdn.spankbang.com/v",
            "https://onlyfans.com/someone", "pornhub.com/foo", "https://myporn.net", "HTTPS://WWW.REDTUBE.COM/"
        ]
        for url in adultURLs {
            assertTest(AdultSiteMatcher.isAdult(urlOrHost: url), "Adult site blocked: \(url)")
        }
        let safeURLs = [
            "https://www.google.com/search?q=porn", "https://essex.ac.uk", "https://sussex.org/about",
            "https://en.wikipedia.org/wiki/Pornography", "https://github.com", "https://twitter.com",
            "https://adultswim.com", "about:blank", "chrome://settings", "how to cook rice", "", "localhost:3000"
        ]
        for url in safeURLs {
            assertTest(!AdultSiteMatcher.isAdult(urlOrHost: url), "Not flagged as adult: \(url.isEmpty ? "(empty)" : url)")
        }
        assertTest(AdultSiteMatcher.host(from: "https://user:pw@www.example.com:8080/path?x#y") == "www.example.com",
                   "Host extraction strips scheme, credentials, port, path, query and fragment")

        // Adult searches on any site, and title fallback
        let adultSearches = [
            "https://www.google.com/search?q=free+porn", "https://www.bing.com/search?q=nude%20pics&form=x",
            "https://duckduckgo.com/?q=hentai", "https://www.youtube.com/results?search_query=naked+people",
            "https://www.reddit.com/search/?q=nsfw", "https://search.yahoo.com/search?p=pornstars",
            "https://www.google.com/search?hl=en&q=best+xxxvideos#top"
        ]
        for url in adultSearches {
            assertTest(AdultSiteMatcher.isAdultSearch(urlOrHost: url), "Adult search blocked: \(url)")
        }
        let safeSearches = [
            "https://www.google.com/search?q=essex+weather", "https://www.google.com/search?q=swift+analytics",
            "https://www.youtube.com/watch?v=abc", "https://github.com/search?q=matcher", "https://example.com/?page=2",
            "https://www.google.com/search?q=peacock+tv", "https://example.com"
        ]
        for url in safeSearches {
            assertTest(!AdultSiteMatcher.isAdultSearch(urlOrHost: url), "Normal search allowed: \(url)")
        }
        assertTest(AdultSiteMatcher.isAdultTitle("Free Porn Videos - XVideos"), "Adult page title recognised")
        assertTest(!AdultSiteMatcher.isAdultTitle("Inbox (3) - Gmail"), "Normal page title ignored")
        assertTest(AdultSiteMatcher.isAdult(urlOrHost: "https://www.redgifs.com/watch/x"), "Adult gif host blocked")
        assertTest(AdultSiteMatcher.isAdult(urlOrHost: "https://jav.guru/x"), "Short adult token host blocked")
        assertTest(!AdultSiteMatcher.isAdult(urlOrHost: "https://www.analyticsvidhya.com"), "Words like 'analytics' are not flagged")

        // -------------------------------------------------------------
        // Test 14: Large blocklist index and page-content scorer
        // -------------------------------------------------------------
        print("\n--- Test 14: Blocklist Index & Content Scorer ---")
        let sampleList = """
        # Title: sample hosts file
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 bad-site.example   # trailing comment
        0.0.0.0 Another.Adult.Test
        0.0.0.0 *.wild.example
        plain-domain.example
        0.0.0.0 not_valid!.example
        10.0.0.1
        0.0.0.0 google.com
        """
        let sampleIndex = AdultDomainIndex(hashes: AdultDomainIndex.parse(Array(sampleList.utf8)))
        assertTest(sampleIndex.count == 5, "Hosts-format list parses to 5 domains (comments, IPs, localhost, invalid skipped)")
        assertTest(sampleIndex.containsHost("bad-site.example") && sampleIndex.containsHost("a.b.bad-site.example"), "Listed domain and its subdomains match")
        assertTest(sampleIndex.containsHost("ANOTHER.adult.TEST"), "Matching is case-insensitive")
        assertTest(sampleIndex.containsHost("wild.example") && sampleIndex.containsHost("x.wild.example"), "Wildcard entries match")
        assertTest(!sampleIndex.containsHost("example") && !sampleIndex.containsHost("localhost"), "Bare TLDs and localhost never match")
        assertTest(!sampleIndex.containsHost("google.com") && !sampleIndex.containsHost("mail.google.com"), "Never-block list overrides a wrong list entry")
        assertTest(AdultDomainIndex(serialized: sampleIndex.serialized()).hashes == sampleIndex.hashes, "Index survives a save/load round trip")

        AdultSiteMatcher.domainLookup = { sampleIndex.containsHost($0) }
        assertTest(AdultSiteMatcher.isAdult(urlOrHost: "https://www.bad-site.example/page"), "Matcher consults the downloaded blocklists")
        AdultSiteMatcher.domainLookup = nil
        assertTest(!AdultSiteMatcher.isAdult(urlOrHost: "https://www.bad-site.example/page"), "Without a lookup only built-in rules apply")

        assertTest(AdultContentScorer.isAdultContent("Free Porn Videos - XXX Tube. Nude naked girls hentai. Are you 18? You must be 18"), "Obvious adult page is flagged")
        assertTest(AdultContentScorer.isAdultContent("This site contains adult content. You must be 18 years of age or older to enter."), "Age-gate page is flagged")
        assertTest(!AdultContentScorer.isAdultContent("Inbox (3) - Gmail. Meeting notes for Monday. Weather in Essex. Swift analytics dashboard."), "Ordinary page is not flagged")
        assertTest(!AdultContentScorer.isAdultContent("Sex education for teens: what parents should know about sexual health and puberty."), "Health article stays below the threshold")
        assertTest(!AdultContentScorer.isAdultContent("porn porn porn porn porn porn porn porn"), "One repeated word cannot trip it alone")
        // Ordinary pages that use a few risqué words must never be flagged.
        let youtubeLike = "Sexy Back - Justin Timberlake (Official Video). 1.2B views. Comments: so sexy, sex bomb, he is naked in this scene lol, Naked and Afraid is better. Up next: Sexy and I Know It; Nude descending a staircase"
        assertTest(!AdultContentScorer.isAdultContent(youtubeLike), "A YouTube page with risqué titles and comments is not flagged")
        let newsLike = "Report: nude photo leak, naked truth about the sexual harassment case. Sex crimes unit says the explicit content was shared online."
        assertTest(!AdultContentScorer.isAdultContent(newsLike), "A news story about an adult-themed case is not flagged")
        assertTest(!AdultContentScorer.isAdultContent("Swimwear sale: sexy bikini, topless sunbathing guide, nude beach etiquette"), "A shop or travel page with a few risqué words is not flagged")
        assertTest(AdultContentScorer.isAdultContent("Free Porn Videos. XXX Hardcore Milf Anal Creampie Hentai. Pornstars on camera. Naked teens."), "A page packed with explicit terms is still flagged")
        assertTest(AdultContentScorer.isAdultContent("Sexually explicit content. You must be 18 years of age or older to enter. Adult content."), "A warning-only age gate is still flagged")

        // Everyday sites are never judged; adult sites and search engines never get that pass.
        assertTest(TrustedSites.isTrusted(urlOrHost: "https://www.youtube.com/watch?v=abc"), "YouTube is trusted")
        assertTest(TrustedSites.isTrusted(urlOrHost: "m.youtube.com") && TrustedSites.isTrusted(urlOrHost: "https://music.youtube.com/"), "YouTube subdomains are trusted")
        assertTest(TrustedSites.isTrusted(urlOrHost: "https://en.wikipedia.org/wiki/Nude_(art)"), "Wikipedia is trusted")
        assertTest(TrustedSites.isTrusted(urlOrHost: "https://www.amazon.com/s?k=swimsuit"), "Shopping sites are trusted")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://www.google.com/search?q=cats&udm=2"), "Google Images is NOT trusted: image results stay watched")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://www.bing.com/images/search?q=mountain"), "Bing Images is NOT trusted")
        assertTest(TrustedSites.isTrusted(urlOrHost: "https://docs.google.com/document/d/1") && !TrustedSites.isTrusted(urlOrHost: "https://sites.google.com/x"), "Only the everyday parts of Google are trusted")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://notyoutube.com/"), "A look-alike host is not trusted")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://youtube.com.example.xxx/"), "A trusted name inside an adult host is not trusted")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://www.youtube.com/results?search_query=porn"), "An explicit search on a trusted site is still blocked")
        assertTest(!TrustedSites.isTrusted(urlOrHost: "https://pornhub.com/"), "An adult site is never trusted")
        assertTest(!TrustedSites.isTrusted(urlOrHost: ""), "An unreadable address is not trusted")

        // -------------------------------------------------------------
        // Test 15: Disguised search terms, and safe image searches stay open
        // -------------------------------------------------------------
        print("\n--- Test 15: Disguised Terms & Safe Image Searches ---")
        let imageSearchUrls = [
            "https://www.google.com/search?q=cats&udm=2", "https://www.google.com/search?q=cats&tbm=isch",
            "https://www.bing.com/images/search?q=mountain+sunset", "https://duckduckgo.com/?q=recipes&iax=images&ia=images"
        ]
        for url in imageSearchUrls {
            assertTest(!AdultSiteMatcher.isAdultSearch(urlOrHost: url) && !AdultSiteMatcher.isAdult(urlOrHost: url), "Safe image search is allowed: \(url)")
        }
        let explicitImageSearchUrls = [
            "https://www.google.com/search?q=porn&udm=2", "https://www.google.com/search?q=nude+pics&tbm=isch",
            "https://www.bing.com/images/search?q=hentai"
        ]
        for url in explicitImageSearchUrls {
            assertTest(AdultSiteMatcher.isAdultSearch(urlOrHost: url), "Explicit image search is still blocked: \(url)")
        }
        let disguised = [
            "https://www.google.com/search?q=p0rn", "https://www.google.com/search?q=pooorn",
            "https://www.google.com/search?q=p+o+r+n", "https://www.google.com/search?q=s3x+videos",
            "https://www.google.com/search?q=bukkake", "https://www.google.com/search?q=s3xy+pics"
        ]
        for url in disguised {
            assertTest(AdultSiteMatcher.isAdultSearch(urlOrHost: url), "Disguised adult search caught: \(url)")
        }
        let innocent = [
            "https://www.google.com/search?q=1080p+monitor", "https://www.google.com/search?q=room+305",
            "https://www.google.com/search?q=a+b+c+d", "https://www.google.com/search?q=moby+dick"
        ]
        for url in innocent {
            assertTest(!AdultSiteMatcher.isAdultSearch(urlOrHost: url), "Innocent search allowed: \(url)")
        }

        // Explicit male-oriented vocabulary is caught; ordinary gay-themed and everyday searches are not.
        // (Being gay is never the trigger: only explicit terms and phrases are.)
        func googleSearch(_ phrase: String) -> String { "https://www.google.com/search?q=" + phrase.replacingOccurrences(of: " ", with: "+") }
        for phrase in ["twink", "twinks", "gay twinks", "bareback", "bareback gay", "gay cam", "gay cams live", "dick pics", "big cock",
                       "big dick", "jerk off", "jerking off", "suck cock", "hung guys", "bussy", "cocksucker", "dildo", "gaysex",
                       "gay porn", "gay sex videos", "naked men", "nude men", "gay xxx"] {
            assertTest(AdultSiteMatcher.isAdultSearch(urlOrHost: googleSearch(phrase)), "Explicit search caught: \(phrase)")
        }
        for phrase in ["gay rights", "gay pride parade", "gay marriage", "gay bar near me", "gay history museum", "queer film festival",
                       "twinkle lights", "peacock", "cocktail recipes", "dickens novels", "moby dick", "bear grylls", "big cockatoo",
                       "hard dickens", "cock robin nursery rhyme", "rooster", "hung up the phone", "jerk chicken recipe", "bareback riding horse"] {
            let blocked = AdultSiteMatcher.isAdultSearch(urlOrHost: googleSearch(phrase))
            // "bareback riding horse" does contain the word bareback: a rodeo search is the accepted cost of that term.
            if phrase == "bareback riding horse" { continue }
            assertTest(!blocked, "Ordinary search allowed: \(phrase)")
        }
        for host in ["https://free-twinks-videos.com/", "https://gaytube-hd.net/", "https://bareback-vids.org/", "https://best-gaysex.net/"] {
            assertTest(AdultSiteMatcher.isAdult(urlOrHost: host), "Adult address caught by name: \(host)")
        }
        for host in ["https://twinkle.com/", "https://gayrights.org/", "https://gaymarriage.org/", "https://peacockfarm.com/", "https://dickinson.edu/"] {
            assertTest(!AdultSiteMatcher.isAdult(urlOrHost: host), "Ordinary address allowed: \(host)")
        }
        let maleExplicitPage = "Twink bareback hardcore cock sucking naked jocks jerking off big dick cum eating. 18+ only adult content."
        assertTest(AdultContentScorer.isAdultContent(maleExplicitPage), "Explicit male-oriented page text is flagged even without the word porn")
        let ordinaryPages = [
            "Gay rights advocates celebrated the court ruling on marriage equality today. Pride parade organisers said the festival would go ahead.",
            "How to raise a cock rooster on a small farm. Peacock feathers and hen coop tips for beginners.",
            "The comment thread was full of swearing: fuck this, fucking awful, what the fuck, fucked up service. Dick Cheney memoir review."
        ]
        for text in ordinaryPages {
            assertTest(!AdultContentScorer.isAdultContent(text), "Ordinary page text left alone: \(text.prefix(40))…")
        }

        // Reddit: adult communities and explicit post titles are blocked by address; ordinary pages and
        // recovery communities are not.
        for page in ["https://www.reddit.com/r/TwinkFemboyPorn/comments/1xe3db5/twink_in_the_sun/",
                     "https://www.reddit.com/r/gonewild30plus/", "https://old.reddit.com/r/nsfw_gifs/top/?t=week",
                     "https://www.reddit.com/r/AnyCommunity/comments/abc123/hardcore_blowjob_compilation/",
                     "https://www.reddit.com/r/pics/comments/abc123/new_nudes_collection/"] {
            assertTest(AdultSiteMatcher.isAdultCommunityPage(urlOrHost: page), "Adult Reddit page caught: \(page)")
        }
        for page in ["https://www.reddit.com/r/NoFap/", "https://www.reddit.com/r/pornfree/comments/abc123/day_30_relapse/",
                     "https://www.reddit.com/r/relationships/comments/abc123/my_boyfriend_watches_porn_and_lies/",
                     "https://www.reddit.com/r/mildlyinfuriating/comments/abc123/what_the_fuck_is_this/",
                     "https://www.reddit.com/r/Biohacking/", "https://www.reddit.com/r/aww/comments/abc123/blue_tits_on_my_feeder/",
                     "https://www.reddit.com/search/?q=cats", "https://www.reddit.com/", "https://example.com/r/porn/",
                     "https://notreddit.com/r/nsfw/", "about:blank"] {
            assertTest(!AdultSiteMatcher.isAdultCommunityPage(urlOrHost: page), "Ordinary Reddit page left alone: \(page)")
        }

        // Hentai and other drawn porn, straight and gay, on Reddit and in searches; ordinary anime stays open.
        for page in ["https://www.reddit.com/r/hentai/", "https://www.reddit.com/r/Hentai_Irl/", "https://www.reddit.com/r/yaoi/",
                     "https://www.reddit.com/r/gayhentai/", "https://www.reddit.com/r/ecchi/", "https://www.reddit.com/r/Doujinshi/",
                     "https://www.reddit.com/r/ahegao/", "https://www.reddit.com/r/futanari/", "https://www.reddit.com/r/Paizuri/",
                     "https://www.reddit.com/r/OppaiLove/", "https://www.reddit.com/r/LewdGames/", "https://www.reddit.com/r/lolicon/",
                     "https://www.reddit.com/r/rule34/", "https://www.reddit.com/r/pics/comments/abc123/new_futanari_art/"] {
            assertTest(AdultSiteMatcher.isAdultCommunityPage(urlOrHost: page), "Drawn-porn Reddit page caught: \(page)")
        }
        for page in ["https://www.reddit.com/r/anime/", "https://www.reddit.com/r/manga/", "https://www.reddit.com/r/Animemes/",
                     "https://www.reddit.com/r/yuri/", "https://www.reddit.com/r/LolitaFashion/", "https://www.reddit.com/r/BoysLove/",
                     "https://www.reddit.com/r/Genshin_Impact/comments/abc/futaba_cosplay/", "https://www.reddit.com/r/manga/comments/abc/yaoi_manga_recommendations/"] {
            assertTest(!AdultSiteMatcher.isAdultCommunityPage(urlOrHost: page), "Ordinary anime Reddit page left alone: \(page)")
        }
        for phrase in ["hentai", "yaoi hentai", "yaoi", "gay hentai", "futanari", "ahegao", "paizuri", "oppai", "rule 34", "rule34", "lewd anime girls"] {
            assertTest(AdultSiteMatcher.isAdultSearch(urlOrHost: googleSearch(phrase)), "Drawn-porn search caught: \(phrase)")
        }
        for phrase in ["anime", "yuri", "manga recommendations", "attack on titan", "sailor moon", "futaba persona", "studio ghibli films"] {
            assertTest(!AdultSiteMatcher.isAdultSearch(urlOrHost: googleSearch(phrase)), "Ordinary anime search allowed: \(phrase)")
        }
        for host in ["https://free-yaoi-manga.net/", "https://futanari-art.com/", "https://ahegao-gallery.org/"] {
            assertTest(AdultSiteMatcher.isAdult(urlOrHost: host), "Drawn-porn address caught by name: \(host)")
        }
        assertTest(AdultContentScorer.isAdultContent("Free hentai doujinshi: yaoi futanari ahegao galleries. 18+ only. Adult content. Oppai paizuri ecchi."), "A drawn-porn page is flagged by its text")
        assertTest(!AdultContentScorer.isAdultContent("Weekly anime news: new ecchi comedy announced, manga chapter list and doujinshi event dates at the convention."), "An anime news page is not")

        // Social feeds are not judged by their page text; adult addresses on them still are.
        for page in ["https://www.reddit.com/", "https://www.reddit.com/r/all/", "https://old.reddit.com/r/popular/", "https://x.com/home",
                     "https://www.instagram.com/", "https://www.youtube.com/watch?v=abc"] {
            assertTest(TrustedSites.skipsPageTextScan(urlOrHost: page), "Page text is not scored on: \(page)")
        }
        for page in ["https://www.reddit.com/r/TwinkFemboyPorn/", "https://www.reddit.com/search/?q=porn", "https://pornhub.com/",
                     "https://www.example.com/", "https://www.reddit.com/r/pics/comments/abc/new_nudes_collection/", ""] {
            assertTest(!TrustedSites.skipsPageTextScan(urlOrHost: page), "Page text is still scored on: \(page)")
        }
        // Everyday swearing and everyday words that merely sound rude never add up on their own.
        let sweary = "Fuck this. Fucking awful service. What the fuck. Fucked up again. Summa cum laude graduate. Cock rooster crowing. That dick move. Moby Dick. Big dicks energy."
        assertTest(AdultContentScorer.analyse(sweary).score == 0, "Swearing and everyday rude-sounding words score nothing")
        let explained = AdultContentScorer.analyse(maleExplicitPage)
        assertTest(explained.terms.contains("twinkx1") && explained.terms.count <= 8, "A flagged page reports which terms it scored on")

        // -------------------------------------------------------------
        // Test 16: Launch agent definition (start at login / relaunch if killed)
        // -------------------------------------------------------------
        print("\n--- Test 16: Launch Agent Plist ---")
        let agentPath = "/Users/someone/word blocker/WordBlocker.app/Contents/MacOS/WordBlocker"
        let agent = LaunchAgentPlist.make(label: "com.wordblocker.app.agent", executable: agentPath)
        assertTest(agent["RunAtLoad"] as? Bool == true, "Agent starts at login")
        assertTest((agent["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false, "Agent restarts only after an abnormal exit (a normal quit stays quit)")
        assertTest(agent["AbandonProcessGroup"] as? Bool == true, "Hand-over helper may outlive the app")
        let agentData = try! LaunchAgentPlist.data(label: "com.wordblocker.app.agent", executable: agentPath)
        assertTest(LaunchAgentPlist.executable(in: agentData) == agentPath, "Agent file round-trips with a path containing a space")
        assertTest(LaunchAgentPlist.executable(in: Data("not a plist".utf8)) == nil, "A broken agent file is rejected")
        assertTest(LaunchAgentPlist.shellQuote("/a b/it's") == "'/a b/it'\\''s'", "Shell quoting handles spaces and apostrophes")
        assertTest((agent["ThrottleInterval"] as? Int ?? 99) <= 2, "A killed app is restarted by launchd within about 2 seconds")
        assertTest(LaunchAgentPlist.isCurrent(agentData, label: "com.wordblocker.app.agent", executable: agentPath), "A freshly written agent file is current")
        var staleAgent = LaunchAgentPlist.make(label: "com.wordblocker.app.agent", executable: agentPath)
        staleAgent["ThrottleInterval"] = 5
        let staleData = try! PropertyListSerialization.data(fromPropertyList: staleAgent, format: .xml, options: 0)
        assertTest(!LaunchAgentPlist.isCurrent(staleData, label: "com.wordblocker.app.agent", executable: agentPath), "An older agent file (slow restart) is detected and gets rewritten")
        assertTest(!LaunchAgentPlist.isCurrent(agentData, label: "com.wordblocker.app.agent", executable: "/elsewhere/WordBlocker"), "An agent file for a moved app is detected")
        assertTest(!LaunchAgentPlist.isCurrent(Data("not a plist".utf8), label: "x", executable: "y"), "A broken agent file is never current")

        // -------------------------------------------------------------
        // Test 16b: Guardian process helpers (pid files, liveness)
        // -------------------------------------------------------------
        print("\n--- Test 16b: Guardian helpers ---")
        assertTest(Guardian.parsePid("4242\n") == 4242, "A pid file with a trailing newline parses")
        assertTest(Guardian.parsePid("  77 ") == 77, "Whitespace around a pid is ignored")
        assertTest(Guardian.parsePid("") == nil && Guardian.parsePid("abc") == nil, "Junk is not a pid")
        assertTest(Guardian.parsePid("0") == nil && Guardian.parsePid("1") == nil && Guardian.parsePid("-5") == nil, "pid 0, 1 and negatives are never accepted")
        assertTest(Guardian.isAlive(getpid()), "This process counts as alive")
        assertTest(!Guardian.isAlive(2_000_000_000), "A pid that doesn't exist is not alive")
        assertTest(!Guardian.isAlive(0) && !Guardian.isAlive(1), "pid 0 and 1 are never treated as ours")
        assertTest(Guardian.isOurs(getpid()), "A live process running this same program is recognised as ours")
        assertTest(!Guardian.isOurs(2_000_000_000), "A dead pid is not ours")
        assertTest(Guardian.argument == "--guardian", "The guardian flag is stable (the app re-launches itself with it)")
        let guardianTemp = FileManager.default.temporaryDirectory.appendingPathComponent("wb-guardian-\(getpid())")
        Guardian.directory = guardianTemp
        try? FileManager.default.createDirectory(at: guardianTemp, withIntermediateDirectories: true)
        Guardian.writePid(31337, to: Guardian.appPidFile)
        assertTest(Guardian.readPid(Guardian.appPidFile) == 31337, "A pid written to the app pid file reads back")
        assertTest(Guardian.readPid(Guardian.guardianPidFile) == nil, "A missing pid file reads as nil")
        Guardian.prepareForCleanExit()
        assertTest(FileManager.default.fileExists(atPath: Guardian.quittingMarker.path), "A confirmed quit leaves the marker the guardian looks for")
        try? FileManager.default.removeItem(at: guardianTemp)

        // -------------------------------------------------------------
        // Test 16c: Unkillable mode (root watchdog): installer text and process lookup
        // -------------------------------------------------------------
        print("\n--- Test 16c: Watchdog (unkillable mode) ---")
        let watchdogPlist = Watchdog.plist(executable: Watchdog.installedExecutable, appPath: "/Applications/Word Blocker.app", uid: 501)
        assertTest(watchdogPlist["Label"] as? String == "com.wordblocker.watchdog", "The watchdog has its own launchd label")
        assertTest(watchdogPlist["KeepAlive"] as? Bool == true && watchdogPlist["RunAtLoad"] as? Bool == true, "The watchdog starts at boot and is restarted if it ever exits")
        assertTest((watchdogPlist["ProgramArguments"] as? [String]) == [Watchdog.installedExecutable, "--watchdog", "/Applications/Word Blocker.app", "501"], "The watchdog is told which app and which user to guard")
        assertTest(Watchdog.installedExecutable.hasPrefix("/Library/"), "The program that runs as root lives in a root-owned folder, not inside the user's app")

        let installText = try! Watchdog.installScript(sourceExecutable: "/Applications/It's here/WordBlocker.app/Contents/MacOS/WordBlocker", appPath: "/Applications/Word Blocker.app", uid: 501)
        assertTest(installText.hasPrefix("set -e;"), "The installer stops at the first failed step")
        assertTest(installText.contains("trap "), "A failed install removes what it put down")
        assertTest(installText.contains("'/Applications/It'\\''s here/WordBlocker.app/Contents/MacOS/WordBlocker'"), "A source path with a space and an apostrophe is quoted safely")
        let bootoutAt = installText.range(of: "bootout")?.lowerBound
        let copyAt = installText.range(of: "/bin/cp -f")?.lowerBound
        let bootstrapAt = installText.range(of: "bootstrap system")?.lowerBound
        assertTest(bootoutAt != nil && copyAt != nil && bootstrapAt != nil && bootoutAt! < copyAt! && copyAt! < bootstrapAt!, "The old helper is stopped before its file is replaced, and the new one is started last")
        assertTest(installText.contains("chown -R root:wheel") && installText.contains("chmod 644"), "Installed files are owned by root and not writable by the user")
        let carried = installText.components(separatedBy: "echo '")[1].components(separatedBy: "'")[0]
        let carriedPlist = Data(base64Encoded: carried).flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [String: Any]
        assertTest((carriedPlist?["ProgramArguments"] as? [String])?.first == Watchdog.installedExecutable, "The launchd file travels inside the command and runs the root-owned copy")
        assertTest(!installText.contains("/tmp"), "No temporary file is involved that another program could swap")

        assertTest(Watchdog.stopScript.contains("bootout") && Watchdog.stopScript.hasSuffix("|| true"), "Stopping for a quit works even if the helper isn't loaded")
        assertTest(Watchdog.uninstallScript.contains("rm -f") && Watchdog.uninstallScript.contains("rm -rf"), "Uninstalling removes the file and the folder")
        let adminScript = Watchdog.appleScript(running: "echo \"hi\" \\ there")
        assertTest(adminScript.hasPrefix("do shell script \"") && adminScript.hasSuffix("\" with administrator privileges"), "The installer is run through macOS's own administrator prompt")
        assertTest(adminScript.contains("echo \\\"hi\\\" \\\\ there"), "Quotes and backslashes survive being wrapped in AppleScript")

        var ownPathBuffer = [CChar](repeating: 0, count: 4096)
        _ = proc_pidpath(getpid(), &ownPathBuffer, 4096)
        let ownPath = String(cString: ownPathBuffer)
        assertTest(Watchdog.pids(ofExecutable: ownPath, owner: getuid()).contains(getpid()), "The watchdog's process lookup finds a running program by its path and owner")
        assertTest(Watchdog.pids(ofExecutable: "/no/such/program", owner: getuid()).isEmpty, "A program that isn't running is not found")
        assertTest(Watchdog.consoleUser() != nil, "The owner of the screen can be read")

        // -------------------------------------------------------------
        // Test 17: Screen image scanner decisions (change detection, tiles, verdicts, pacing)
        // -------------------------------------------------------------
        print("\n--- Test 17: Image Scan Logic ---")
        let still = [UInt8](repeating: 100, count: 640)
        assertTest(ImageScanLogic.difference(still, still) == 0, "Identical screens have no difference")
        assertTest(ImageScanLogic.difference(still, [UInt8](repeating: 103, count: 640)) < ImageScanLogic.changeThreshold, "A tiny brightness flicker does not count as a change")
        var withPicture = still
        for index in 0..<64 { withPicture[index] = 220 }   // a picture appearing over 10% of the screen
        assertTest(ImageScanLogic.difference(still, withPicture) >= ImageScanLogic.changeThreshold, "A new picture counts as a change")
        assertTest(ImageScanLogic.difference(still, [1, 2, 3]) == 1, "Mismatched thumbnails are treated as changed")

        let tiles = ImageScanLogic.tiles(width: 640, height: 400)
        assertTest(tiles.count == 14 && tiles[0] == ImageScanLogic.Tile(x: 0, y: 0, width: 640, height: 400), "Whole screen, a 2x2 grid and a 3x3 grid are scanned")
        assertTest(tiles[1...4].reduce(0) { $0 + $1.width * $1.height } == 640 * 400, "The four quarters exactly cover the screen")
        assertTest(tiles[5...13].reduce(0) { $0 + $1.width * $1.height } == 640 * 400, "The nine ninths exactly cover the screen")
        assertTest(tiles[5] == ImageScanLogic.Tile(x: 0, y: 0, width: 213, height: 133) && tiles[9] == ImageScanLogic.Tile(x: 213, y: 133, width: 213, height: 133), "The 3x3 grid runs row by row; its middle tile is the centre of the screen")
        let oddTiles = ImageScanLogic.tiles(width: 641, height: 401)
        assertTest(oddTiles[1...4].reduce(0) { $0 + $1.width * $1.height } == 641 * 401
                   && oddTiles[5...13].reduce(0) { $0 + $1.width * $1.height } == 641 * 401, "Odd screen sizes are still covered exactly")
        assertTest(ImageScanLogic.tiles(width: 2, height: 2).count == 1, "A tiny image is scanned whole")
        assertTest(ImageScanLogic.captureLongSide == 1280, "The model looks at a 1280 px screenshot, up from 640")

        assertTest(ImageScanLogic.verdict(scores: [0.1, 0.2], previouslySuspect: false) == .clear, "Low scores are clear")
        assertTest(ImageScanLogic.verdict(scores: [0.1, 0.995], previouslySuspect: false) == .explicit, "An overwhelming score acts at once")
        assertTest(ImageScanLogic.verdict(scores: [0.95], previouslySuspect: false) == .suspect, "A high score is rechecked first")
        assertTest(ImageScanLogic.verdict(scores: [0.95], previouslySuspect: true) == .explicit, "Two high scans in a row act")
        assertTest(ImageScanLogic.verdict(scores: [0.9], previouslySuspect: false) == .clear, "A score of 0.9 no longer counts: films and beach photos score that")
        assertTest(ImageScanLogic.verdict(scores: [0.9], previouslySuspect: true) == .clear, "...even on a second look")
        assertTest(ImageScanLogic.verdict(scores: [], previouslySuspect: false) == .clear, "No scores means clear")

        // Search results pages (a mosaic of thumbnails) get a much stricter bar.
        assertTest(ImageScanLogic.verdict(scores: [0.995], previouslySuspect: false, onSearchResults: false) == .explicit, "Off a search page 0.995 acts at once")
        assertTest(ImageScanLogic.verdict(scores: [0.995], previouslySuspect: false, onSearchResults: true) == .suspect, "On a search page 0.995 is only suspect")
        assertTest(ImageScanLogic.verdict(scores: [0.995], previouslySuspect: true, onSearchResults: true) == .explicit, "...and acts if it holds on the next look")
        assertTest(ImageScanLogic.verdict(scores: [0.99], previouslySuspect: true, onSearchResults: true) == .clear, "On a search page 0.99 never acts, even twice")
        assertTest(ImageScanLogic.verdict(scores: [0.9985], previouslySuspect: false, onSearchResults: true) == .explicit, "A near-certain score still acts on a search page")
        assertTest(ImageScanLogic.verdict(scores: [0.95], previouslySuspect: false) == .suspect, "The default (not a search page) is unchanged")
        for page in ["https://www.google.com/search?q=stanford+students&udm=2", "https://www.google.co.uk/search?q=x&tbm=isch",
                     "https://www.bing.com/images/search?q=x", "https://duckduckgo.com/?q=x&iax=images", "https://search.brave.com/images?q=x"] {
            assertTest(ImageScanLogic.isSearchResultsPage(page), "Search results page: \(page)")
        }
        for page in ["https://www.example.com/gallery", "https://www.reddit.com/r/pics", "https://notgoogle.com/", "about:blank", ""] {
            assertTest(!ImageScanLogic.isSearchResultsPage(page), "Not a search results page: \(page)")
        }

        // A coarse hit must be backed up by the finer tiles inside it. The score lists below are real scans from
        // the block log (whole | 2x2 | 3x3), at the 1280x800 the scanner captures.
        let scanTiles = ImageScanLogic.tiles(width: 1280, height: 800)
        func decided(_ scores: [Double], search: Bool) -> ImageScanLogic.Verdict {
            ImageScanLogic.verdict(scores: ImageScanLogic.supportedScores(scores, tiles: scanTiles), previouslySuspect: false, onSearchResults: search)
        }
        let hangoverSearch = [0.005, 0.004, 0.003, 1.000, 0.000, 0.001, 0.001, 0.002, 0.000, 0.058, 0.000, 0.013, 0.030, 0.051]
        assertTest(ImageScanLogic.verdict(scores: hangoverSearch, previouslySuspect: false, onSearchResults: true) == .explicit, "Without the check, that Google Images scan closed the tab")
        assertTest(decided(hangoverSearch, search: true) == .clear && decided(hangoverSearch, search: false) == .clear,
                   "A quarter at 1.000 with every tile inside it under 0.06 is the model misreading the page: left alone")
        let realPictureEverywhere = [0.879, 0.003, 0.510, 0.421, 0.985, 0.001, 0.001, 0.002, 0.975, 0.057, 0.037, 0.012, 0.999, 0.012]
        assertTest(decided(realPictureEverywhere, search: true) == .explicit, "A picture the finer tiles agree on still acts, even on a search page")
        let realFeedPicture = [0.997, 0.959, 0.933, 0.059, 0.367, 0.003, 0.420, 0.003, 0.524, 1.000, 0.010, 0.010, 0.688, 0.005]
        assertTest(decided(realFeedPicture, search: false) == .explicit, "A whole-screen hit with finer tiles that agree still acts")
        let smallPictureInFeed = [0.014, 0.001, 0.001, 0.001, 0.000, 0.001, 0.003, 0.001, 0.018, 0.998, 0.000, 0.001, 0.000, 0.001]
        assertTest(decided(smallPictureInFeed, search: false) == .explicit, "A small picture caught only by a 3x3 tile (nothing finer to check) still acts")
        let wholeAloneHigh = [0.998] + [Double](repeating: 0.001, count: 13)
        assertTest(decided(wholeAloneHigh, search: false) == .clear, "A whole-screen hit with every tile under 0.15 is left alone")
        let reelQuarter = [0.637, 0.001, 0.013, 0.979, 0.366, 0.001, 0.003, 0.002, 0.031, 0.000, 0.036, 0.003, 0.011, 0.097]
        assertTest(ImageScanLogic.supportedScores(reelQuarter, tiles: scanTiles)[3] == 0 && ImageScanLogic.supportedScores(reelQuarter, tiles: scanTiles)[0] == 0.637,
                   "Only the unsupported quarter is dropped; other scores are untouched")
        assertTest(ImageScanLogic.supportedScores([0.99, 0.5], tiles: scanTiles) == [0.99, 0.5], "A list that does not match the tiles is returned as it is")
        assertTest(ImageScanLogic.supportedScores(realPictureEverywhere, tiles: scanTiles) == realPictureEverywhere, "Scores the finer tiles agree with are unchanged")
        assertTest(ImageScanLogic.overlap(of: scanTiles[9], inside: scanTiles[1]) < 0.3 && ImageScanLogic.overlap(of: scanTiles[5], inside: scanTiles[1]) == 1,
                   "Tile overlap: the 3x3 centre tile is a quarter inside each 2x2 tile, the corner one fully inside")

        // Explaining a block: where, how sure, which bar, who agreed.
        assertTest(ImageScanLogic.regionName(ofTile: 0, count: 14) == "whole screen" && ImageScanLogic.regionName(ofTile: 3, count: 14) == "bottom-left quarter of the screen"
                   && ImageScanLogic.regionName(ofTile: 9, count: 14) == "centre ninth of the screen" && ImageScanLogic.regionName(ofTile: 13, count: 14) == "bottom-right ninth of the screen"
                   && ImageScanLogic.regionName(ofTile: 5, count: 14) == "top-left ninth of the screen", "Tiles are named by where they sit on the screen")
        assertTest(ImageScanLogic.regionName(ofTile: 2, count: 5) == "tile 2" && ImageScanLogic.regionName(ofTile: 20, count: 14) == "tile 20", "An unexpected layout falls back to the tile number")
        assertTest(ImageScanLogic.percent(0.9985) == "99.9%" && ImageScanLogic.percent(1.0) == "100.0%" && ImageScanLogic.percent(0.5) == "50.0%" && ImageScanLogic.percent(0.0042) == "0.4%",
                   "Scores are written as percentages with one decimal")
        let hitReason = ImageScanLogic.explanation(scores: realFeedPicture, strict: false)
        assertTest(hitReason.hasPrefix("centre ninth of the screen scored 100.0% explicit, at or above the 99.0% bar for acting straight away"), "The reason names the tile, the score and the bar: \(hitReason)")
        assertTest(hitReason.contains("also high: whole screen 99.7%, top-left quarter of the screen 95.9%"), "The reason lists the other tiles that agreed, strongest first: \(hitReason)")
        let searchReason = ImageScanLogic.explanation(scores: smallPictureInFeed, strict: true)
        assertTest(searchReason.contains("a search-results page, so the stricter bars") && searchReason.contains("99.8% bar") && searchReason.contains("no other part of the screen scored above 50.0%"),
                   "A search page says so, and a lone tile says nothing else agreed: \(searchReason)")
        var repeatScores = [Double](repeating: 0.01, count: 14); repeatScores[12] = 0.95
        let repeatReason = ImageScanLogic.explanation(scores: repeatScores, strict: false)
        assertTest(repeatReason.contains("bottom-centre ninth of the screen scored 95.0% explicit on two scans in a row, above the 93.0% bar"), "A repeat sighting says it needed two scans: \(repeatReason)")
        var rawHeld = hangoverSearch; rawHeld[7] = 0.999      // a real small hit elsewhere, plus the unsupported quarter
        let heldReason = ImageScanLogic.explanation(scores: ImageScanLogic.supportedScores(rawHeld, tiles: scanTiles), strict: false, raw: rawHeld)
        assertTest(heldReason.contains("set aside because the finer tiles inside did not agree: bottom-left quarter of the screen 100.0%"), "The reason says which unsupported tile was set aside: \(heldReason)")
        assertTest(ImageScanLogic.explanation(scores: [], strict: false) == "no scores", "No scores, no reason")
        assertTest(ImageScanLogic.describeLabels([("person", 0.93), ("swimwear", 0.41), ("beach", 0.08), ("sky", 0.22)]) == "person 93.0%, swimwear 41.0%, sky 22.0%",
                   "Picture labels: strongest first, weak ones left out")
        assertTest(ImageScanLogic.describeLabels([("a", 0.9), ("b", 0.8), ("c", 0.7)], limit: 2) == "a 90.0%, b 80.0%" && ImageScanLogic.describeLabels([("a", 0.05)]).isEmpty, "Labels are capped, and none is fine")
        assertTest(BlockLog.traceFileURL.lastPathComponent == "scan-trace.log" && BlockLog.traceFileURL != BlockLog.fileURL && BlockLog.traceFileURL.deletingLastPathComponent() == BlockLog.fileURL.deletingLastPathComponent(),
                   "The scan trace goes to its own file beside the block log")

        // Which rule fired: the matcher reports it, without keeping what was typed.
        let siteReason = AdultSiteMatcher.adultSiteReason(urlOrHost: "https://www.pornhub.com/video")
        assertTest(siteReason?.rule == "known-domain" && siteReason?.matched == "pornhub.com", "A known adult site reports the built-in list")
        assertTest(AdultSiteMatcher.adultSiteReason(urlOrHost: "https://example.xxx/")?.rule == "adult-tld" && AdultSiteMatcher.adultSiteReason(urlOrHost: "https://example.xxx/")?.matched == ".xxx", "An adult domain ending reports itself")
        assertTest(AdultSiteMatcher.adultSiteReason(urlOrHost: "https://free-xxx-videos.net/")?.rule == "domain-keyword" && AdultSiteMatcher.adultSiteReason(urlOrHost: "https://free-xxx-videos.net/")?.matched == "xxx", "A keyword in the site name is named")
        assertTest(AdultSiteMatcher.adultSiteReason(urlOrHost: "https://sex-videos.net/")?.rule == "domain-word" && AdultSiteMatcher.adultSiteReason(urlOrHost: "https://sex-videos.net/")?.matched == "sex", "A hyphenated word in the site name is named")
        assertTest(AdultSiteMatcher.adultSiteReason(urlOrHost: "https://www.essex.ac.uk/") == nil, "No reason for an ordinary site")
        AdultSiteMatcher.domainLookup = { $0 == "obscure-site.net" }
        assertTest(AdultSiteMatcher.adultSiteReason(urlOrHost: "https://obscure-site.net/")?.rule == "blocklist", "A site on the downloaded lists reports the blocklists")
        AdultSiteMatcher.domainLookup = nil
        let porn = AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.google.com/search?q=hot+porn+videos&hl=en")
        assertTest(porn?.rule == "search-fragment" && porn?.matched == "porn", "A search names the list entry that matched")
        assertTest(!(porn?.detail.contains("hot") ?? true) && !(porn?.detail.contains("videos") ?? true), "...and does not repeat the other words that were searched")
        assertTest(AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.bing.com/search?q=nude+beach")?.rule == "search-word" && AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.bing.com/search?q=nude+beach")?.matched == "nude", "An explicit word is named")
        assertTest(AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.bing.com/search?q=jerk+off")?.rule == "search-phrase", "An explicit phrase is named")
        let leetReason = AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.google.com/search?q=p0rn")
        assertTest(leetReason?.matched == "porn" && leetReason?.detail.contains("disguised spelling") == true && !(leetReason?.detail.contains("p0rn") ?? true), "A disguised spelling says so, without the typed form")
        assertTest(AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.google.com/search?q=p+o+r+n")?.detail.contains("letter by letter") == true, "A spelled-out word says so")
        assertTest(AdultSiteMatcher.adultSearchReason(urlOrHost: "https://www.google.com/search?q=stanford+students") == nil, "An ordinary search has no reason")
        let community = AdultSiteMatcher.adultCommunityReason(urlOrHost: "https://www.reddit.com/r/Hentai_Irl/")
        assertTest(community?.rule == "community-name" && community?.matched == "hentai", "An adult community names the fragment")
        assertTest(AdultSiteMatcher.adultCommunityReason(urlOrHost: "https://www.reddit.com/r/pics/comments/abc/twink_femboy_getting_tagged/")?.rule == "post-title", "A post title names the word")
        assertTest(AdultSiteMatcher.adultCommunityReason(urlOrHost: "https://www.reddit.com/r/NoFap/") == nil, "A recovery community has no reason")
        assertTest(AdultSiteMatcher.adultTitleReason("Free XXX videos")?.rule == "title-keyword" && AdultSiteMatcher.adultTitleReason("Free XXX videos")?.matched == "xxx", "A page title names the keyword")

        // The structured block log: events, their text, filtering and grouping, and older log lines.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let searchEvent = BlockEvent.website(check: "adult-search", reason: porn!, page: "www.google.com/search", app: "com.google.Chrome", date: stamp)
        assertTest(searchEvent.headline == "Explicit search closed" && searchEvent.action == "Tab closed" && searchEvent.kind == .website && searchEvent.outcome == .blocked, "A website block says what it was")
        assertTest(searchEvent.details.contains(BlockEvent.Detail("Matched", "porn")) && searchEvent.details.contains { $0.label == "Search words" && $0.value.contains("Not saved") }, "A search block shows the match and says the words are not kept")
        let textEvent = BlockEvent.pageText(score: 24, distinct: 5, terms: ["hentaix2", "nudex2"], page: "example.com/gallery", app: "com.apple.Safari", date: stamp)
        assertTest(textEvent.why.contains("scored 24") && textEvent.why.contains("18 or more") && textEvent.why.contains("5 different") && textEvent.why.contains("hentaix2"), "A page-text block explains the score and the limit: \(textEvent.why)")
        let imageEvent = BlockEvent.image(outcome: .blocked, scores: realFeedPicture, decided: realFeedPicture, strict: false, looksLike: "people 93.0%, boxing 41.0%",
                                          action: "Tab closed", page: "www.reddit.com/r/pics", app: "com.google.Chrome", date: stamp)
        assertTest(imageEvent.check == "image-scan" && imageEvent.scores?.count == 14 && imageEvent.why.hasPrefix("centre ninth of the screen scored 100.0% explicit"), "An image block explains the tile and score: \(imageEvent.why)")
        assertTest(["Flagged area", "Model score", "Bar cleared", "Also high", "Apple classifier says"].allSatisfy { label in imageEvent.details.contains { $0.label == label } }, "An image block lists its evidence")
        assertTest(imageEvent.details.first { $0.label == "Bar cleared" }?.value == "99.0% (acts on one scan)", "...including which bar it cleared")
        var heldRaw = hangoverSearch; heldRaw[7] = 0.999
        let heldEvent = BlockEvent.image(outcome: .blocked, scores: heldRaw, decided: ImageScanLogic.supportedScores(heldRaw, tiles: scanTiles), strict: true, looksLike: "",
                                         action: "Tab closed", page: "www.google.com/search", app: "com.google.Chrome", date: stamp)
        assertTest(heldEvent.details.contains { $0.label == "Set aside" && $0.value.contains("bottom-left quarter") } && heldEvent.details.contains { $0.label == "Page type" }, "A set-aside tile and a search page are both shown")
        assertTest(!heldEvent.details.contains { $0.label == "Apple classifier says" }, "No labels, no label row")
        let nearEvent = BlockEvent.image(outcome: .nearMiss, nearMiss: .heldBack, scores: hangoverSearch, decided: ImageScanLogic.supportedScores(hangoverSearch, tiles: scanTiles), strict: false,
                                         looksLike: "", action: "Nothing closed", page: "www.google.com/search", app: "com.google.Chrome", date: stamp)
        assertTest(nearEvent.check == "image-held-back" && nearEvent.outcome == .nearMiss && nearEvent.details.first { $0.label == "Model score" }?.value == "100.0% explicit"
                   && nearEvent.why.contains("set aside"), "A held-back near miss reports the raw score that was set aside: \(nearEvent.why)")
        let recheckEvent = BlockEvent.image(outcome: .nearMiss, nearMiss: .recheck, scores: repeatScores, decided: repeatScores, strict: false, looksLike: "", action: "Nothing closed", page: nil, app: nil, date: stamp)
        assertTest(recheckEvent.check == "image-recheck" && recheckEvent.why.contains("next scan") && recheckEvent.page == nil, "A first sighting says the next scan decides")

        // Stored as JSON lines and read back; unreadable lines are skipped.
        let jsonEncoder = JSONEncoder(); jsonEncoder.dateEncodingStrategy = .iso8601
        let jsonText = [searchEvent, imageEvent, textEvent].map { String(data: try! jsonEncoder.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\nnot json at all\n"
        let readBack = BlockLog.events(fromJSONLines: jsonText)
        assertTest(readBack == [searchEvent, imageEvent, textEvent], "Events survive being written and read back")
        assertTest(BlockLog.trimmedLines("a\nb\nc\nd\n", maxLines: 2) == "c\nd\n" && BlockLog.trimmedLines("a\nb\n", maxLines: 5) == "a\nb\n", "The event file keeps the newest lines")
        assertTest(BlockLog.eventsFileURL.lastPathComponent == "blocks.jsonl" && BlockLog.eventsFileURL.deletingLastPathComponent() == BlockLog.fileURL.deletingLastPathComponent(), "Events live in blocks.jsonl beside the text log")
        assertTest(imageEvent.logLine.contains("why=\"") && imageEvent.logLine.contains("scores(whole | 2x2 | 3x3)=[") && imageEvent.logLine.contains("page=www.reddit.com/r/pics") && imageEvent.logLine.contains("app=com.google.Chrome"), "The text log line carries the reason, scores, app and page")
        assertTest(searchEvent.copyText.contains("Why: The search has a word that contains") && searchEvent.copyText.contains("Page: www.google.com/search") && searchEvent.copyText.contains("Matched: porn"), "Copied details are readable")

        // Filters, search, and grouping by day.
        let everything = [searchEvent, imageEvent, textEvent, nearEvent]
        assertTest(everything.filter { $0.matches(.blocks) }.count == 3 && everything.filter { $0.matches(.images) } == [imageEvent]
                   && everything.filter { $0.matches(.websites) } == [searchEvent, textEvent] && everything.filter { $0.matches(.nearMisses) } == [nearEvent], "Filters split blocks, images, websites and near misses")
        assertTest(searchEvent.matches(search: "") && searchEvent.matches(search: "chrome porn") && searchEvent.matches(search: "GOOGLE") && !searchEvent.matches(search: "porn reddit"), "Search needs every word, in any case, across reason, page and app")
        let noon = Date(timeIntervalSince1970: 1_700_049_600)   // 2023-11-15 12:00 UTC
        assertTest(BlockEvent.dayTitle(for: noon, now: noon, calendar: utc) == "Today" && BlockEvent.dayTitle(for: noon.addingTimeInterval(-86_400), now: noon, calendar: utc) == "Yesterday"
                   && BlockEvent.dayTitle(for: noon.addingTimeInterval(-3 * 86_400), now: noon, calendar: utc) == "Sun 12 Nov" && BlockEvent.dayTitle(for: noon.addingTimeInterval(-400 * 86_400), now: noon, calendar: utc) == "Tue 11 Oct 2022", "Days are grouped as Today, Yesterday or a date")
        assertTest(BlockEvent.timeText(noon.addingTimeInterval(-7 * 3600 + 5 * 60), calendar: utc) == "05:05" && BlockEvent.timeText(noon, calendar: utc) == "12:00", "Times are 24-hour")
        let counted = BlockEvent.counts([searchEvent, imageEvent, nearEvent], now: stamp, calendar: utc)
        assertTest(counted.total == 2 && counted.images == 1 && counted.websites == 1 && counted.today == 2 && counted.week == 2, "Counts ignore near misses")
        assertTest(BlockEvent.counts([], now: stamp, calendar: utc).total == 0, "An empty log counts zero")
        assertTest(BlockEvent.appName("com.google.Chrome") == "Chrome" && BlockEvent.appName("org.example.SomeApp") == "SomeApp" && BlockEvent.appName(nil) == "Unknown app" && BlockEvent.appName("?") == "Unknown app", "App names are readable")

        // Lines from the older plain-text log still show up in the window.
        let oldImage = "2026-11-16 22:37:49  image-scanner  EXPLICIT, tab closed  top=0.9951 tile=3  scores(whole | 2x2 | 3x3)=[0.000 0.011 0.000 0.995 0.000 0.001 0.004 0.000 0.228 0.235 0.001 0.001 0.001 0.000]  strict=false  app=com.google.Chrome  page=www.kobo.com/us/en/ebook/a-future-with-you-yaoi-manga"
        let oldImageEvent = BlockEvent.legacy(line: oldImage)
        assertTest(oldImageEvent?.kind == .image && oldImageEvent?.outcome == .blocked && oldImageEvent?.scores?.count == 14 && oldImageEvent?.app == "com.google.Chrome"
                   && oldImageEvent?.page == "www.kobo.com/us/en/ebook/a-future-with-you-yaoi-manga" && oldImageEvent?.why.contains("bottom-left quarter of the screen") == true, "An older image block is rebuilt with its reason")
        assertTest(oldImageEvent?.copyText.contains("2026-11-16 22:37:49") == true, "...and keeps its time")
        let oldMid = "2026-11-16 22:37:35  image-scanner  mid-score (below the bar, not acted on)  top=0.6650 tile=5  scores(whole | 2x2 | 3x3)=[0.001 0.166 0.000 0.113 0.000 0.665 0.003 0.000 0.453 0.001 0.000 0.599 0.015 0.001]  strict=false  app=com.google.Chrome  page=www.kobo.com/us/en/ebook/x"
        assertTest(BlockEvent.legacy(line: oldMid)?.outcome == .nearMiss && BlockEvent.legacy(line: oldMid)?.check == "image-near-miss", "An older mid-score line becomes a near miss")
        let oldSuspect = "2026-11-16 22:36:20  image-scanner  suspect  top=0.9971 tile=11  scores(whole | 2x2 | 3x3)=[0.002 0.005 0.005 0.995 0.959 0.001 0.003 0.002 0.068 0.002 0.004 0.997 0.000 0.000]  strict=true  app=com.google.Chrome  page=www.google.com/search"
        assertTest(BlockEvent.legacy(line: oldSuspect)?.check == "image-recheck" && BlockEvent.legacy(line: oldSuspect)?.strict == true, "An older suspect line becomes a recheck")
        let oldSearch = BlockEvent.legacy(line: "2026-11-16 22:37:04  website  adult-search  tab closed  page=www.google.com/search")
        assertTest(oldSearch?.kind == .website && oldSearch?.check == "adult-search" && oldSearch?.page == "www.google.com/search" && oldSearch?.why.contains("before reasons were kept") == true, "An older website block says its reason was not recorded")
        let oldText = BlockEvent.legacy(line: "2026-11-16 18:40:00  website  page-text  tab closed  score=31 distinct-terms=6 top-terms=[nudex2, sexyx2, xxxx1]  page=example.com/gallery")
        assertTest(oldText?.check == "page-text" && oldText?.why.contains("scored 31") == true && oldText?.why.contains("nudex2") == true, "An older page-text block keeps its score and terms")
        assertTest(BlockEvent.legacy(line: "2026-11-16 22:40:47  image-scanner  trace  top=0.0034 tile=10  scores(whole | 2x2 | 3x3)=[0.001]  strict=false  app=x  page=y") == nil, "The score trace is not a block")
        assertTest(BlockEvent.legacy(line: "garbage") == nil && BlockEvent.legacy(line: "") == nil, "Unreadable lines are skipped")
        let oldFive = BlockEvent.legacy(line: "2026-11-16 18:22:22  image-scanner  EXPLICIT, tab closed  scores(whole, top-left, top-right, bottom-left, bottom-right)=[0.5586, 0.9980, 0.1333, 0.3633, 0.7656]  strict=false  app=com.google.Chrome  page=www.reddit.com/r/x/")
        assertTest(oldFive?.outcome == .blocked && oldFive?.scores == nil && oldFive?.why.contains("99.8%") == true, "The first five-score format is read without a region map")

        // The body-part detector: reading its output, naming parts, and writing them into the log.
        assertTest(BodyPartLogic.labels.count == 18 && BodyPartLogic.names.count == 18 && BodyPartLogic.labels[3] == "FEMALE_BREAST_EXPOSED" && BodyPartLogic.labels[2] == "BUTTOCKS_EXPOSED"
                   && BodyPartLogic.labels[14] == "MALE_GENITALIA_EXPOSED" && BodyPartLogic.labels[12] == "FACE_MALE", "The detector's 18 classes are in the model's order")
        assertTest(BodyPartLogic.explicitIndices.allSatisfy { BodyPartLogic.labels[$0].hasSuffix("_EXPOSED") && !BodyPartLogic.labels[$0].hasPrefix("MALE_BREAST") && !BodyPartLogic.labels[$0].hasPrefix("BELLY")
                   && !BodyPartLogic.labels[$0].hasPrefix("FEET") && !BodyPartLogic.labels[$0].hasPrefix("ARMPITS") } && BodyPartLogic.explicitIndices.count == 5,
                   "Only exposed genitals, female breast, buttocks and anus count as explicit")
        assertTest(BodyPartLogic.labels.indices.allSatisfy { index in (BodyPartLogic.names[index].contains("(exposed)")) == BodyPartLogic.labels[index].hasSuffix("_EXPOSED") }, "Plain names agree with the class names about exposed and covered")
        // A tiny output table: 4 columns (candidate boxes), 22 rows (x, y, width, height, then 18 class scores).
        func table(_ anchors: [(box: (Float, Float, Float, Float), label: Int, score: Float)]) -> [Float] {
            var values = [Float](repeating: 0, count: 22 * anchors.count)
            for (column, anchor) in anchors.enumerated() {
                values[column] = anchor.box.0; values[anchors.count + column] = anchor.box.1
                values[2 * anchors.count + column] = anchor.box.2; values[3 * anchors.count + column] = anchor.box.3
                values[(4 + anchor.label) * anchors.count + column] = anchor.score
            }
            return values
        }
        let decoded = BodyPartLogic.decode(table([((100, 100, 50, 50), 3, 0.9), ((102, 100, 50, 50), 2, 0.8), ((250, 250, 40, 40), 1, 0.6), ((30, 30, 20, 20), 7, 0.2)]), anchors: 4)
        assertTest(decoded.count == 2 && decoded[0].label == 3 && decoded[0].score == 0.9 && decoded[1].label == 1 && decoded[1].centerX == 250, "Decoding keeps the strongest of overlapping boxes, drops weak ones, strongest first")
        assertTest(BodyPartLogic.decode([0, 1, 2], anchors: 4).isEmpty && BodyPartLogic.decode([], anchors: 0).isEmpty, "A table of the wrong size reads as nothing")
        assertTest(BodyPartLogic.decode(table([((100, 100, 50, 50), 3, 0.3)]), anchors: 1, minimumScore: 0.5).isEmpty, "A box under the minimum score is ignored")
        let boxA = BodyPartLogic.Detection(label: 0, score: 1, centerX: 50, centerY: 50, width: 40, height: 40)
        let boxFar = BodyPartLogic.Detection(label: 0, score: 1, centerX: 200, centerY: 200, width: 40, height: 40)
        let boxHalf = BodyPartLogic.Detection(label: 0, score: 1, centerX: 70, centerY: 50, width: 40, height: 40)
        assertTest(BodyPartLogic.overlap(boxA, boxA) == 1 && BodyPartLogic.overlap(boxA, boxFar) == 0 && abs(BodyPartLogic.overlap(boxA, boxHalf) - 1.0 / 3.0) < 0.001, "Box overlap is intersection over union")
        let found = [BodyPartLogic.Detection(label: 3, score: 0.87, centerX: 0, centerY: 0, width: 1, height: 1), BodyPartLogic.Detection(label: 2, score: 0.72, centerX: 0, centerY: 0, width: 1, height: 1),
                     BodyPartLogic.Detection(label: 3, score: 0.5, centerX: 0, centerY: 0, width: 1, height: 1), BodyPartLogic.Detection(label: 12, score: 0.9, centerX: 0, centerY: 0, width: 1, height: 1),
                     BodyPartLogic.Detection(label: 13, score: 0.61, centerX: 0, centerY: 0, width: 1, height: 1)]
        let summary = BodyPartLogic.summarise(found)
        assertTest(summary.explicit == ["female breast (exposed) 87.0% x2", "buttocks (exposed) 72.0%"] && summary.context == ["face (male) 90.0%", "belly (exposed) 61.0%"], "A summary lists explicit parts and context, best score first, with a count: \(summary)")
        assertTest(BodyPartLogic.sentence(summary) == "The body-part detector found: female breast (exposed) 87.0% x2, buttocks (exposed) 72.0%; also seen: face (male) 90.0%, belly (exposed) 61.0%.", "The sentence for explicit parts")
        assertTest(BodyPartLogic.sentence(BodyPartLogic.summarise([found[3]])) == "The body-part detector found no explicit body part in that area; it saw: face (male) 90.0%.", "The sentence for context only")
        assertTest(BodyPartLogic.sentence(BodyPartLogic.summarise([])).contains("found no body parts") && BodyPartLogic.sentence(BodyPartLogic.summarise([])).contains("drawn or unusual"), "The sentence for nothing explains why drawn pictures are often missed")
        let withParts = BlockEvent.image(outcome: .blocked, scores: realFeedPicture, decided: realFeedPicture, strict: false, looksLike: "", bodyParts: found, action: "Tab closed", page: "x.com/a", app: "com.google.Chrome", date: stamp)
        assertTest(withParts.why.contains("The body-part detector found: female breast (exposed) 87.0% x2") && withParts.details.contains(BlockEvent.Detail("Body parts found", "female breast (exposed) 87.0% x2, buttocks (exposed) 72.0%"))
                   && withParts.details.contains(BlockEvent.Detail("Also seen", "face (male) 90.0%, belly (exposed) 61.0%")), "A block with detector findings says them in the reason and the evidence")
        let noParts = BlockEvent.image(outcome: .blocked, scores: realFeedPicture, decided: realFeedPicture, strict: false, looksLike: "", bodyParts: [], action: "Tab closed", page: "x.com/a", app: nil, date: stamp)
        assertTest(noParts.details.contains(BlockEvent.Detail("Body parts found", "None explicit")) && noParts.details.contains(BlockEvent.Detail("Also seen", "Nothing else")) && noParts.why.contains("found no body parts"), "A detector run that found nothing says so")
        assertTest(!imageEvent.details.contains { $0.label == "Body parts found" } && !imageEvent.why.contains("body-part detector"), "Without the detector's model, the log says nothing about body parts")

        // The block log: what is recorded, and that it never keeps the search words.
        let logLine = BlockLog.line(date: Date(timeIntervalSince1970: 0), reason: "image-scanner", detail: "a\nb")
        assertTest(logLine.hasSuffix("  image-scanner  a b") && !logLine.contains("\n"), "A log entry is one line: reason, then detail")
        assertTest(BlockLog.describePage("https://www.google.com/search?q=stanford+students&udm=2#top") == "www.google.com/search", "Addresses are logged without the query string or fragment")
        assertTest(BlockLog.describePage(nil) == "(address unreadable)" && BlockLog.describePage("  ") == "(address unreadable)", "A missing address is said so")
        assertTest(BlockLog.describePage("https://x.com/" + String(repeating: "a", count: 300)).count == 100, "Long addresses are shortened")
        let manyLines = (1...2000).map { "line \($0) " + String(repeating: "x", count: 60) }.joined(separator: "\n") + "\n"
        let trimmedLog = BlockLog.trimmed(manyLines, maxBytes: 10_000)
        assertTest(trimmedLog.utf8.count <= 10_000 && trimmedLog.hasSuffix("line 2000 " + String(repeating: "x", count: 60) + "\n") && !trimmedLog.contains("line 1 "), "A long log keeps only the newest lines")
        assertTest(BlockLog.trimmed("short\n", maxBytes: 10_000) == "short\n", "A short log is left alone")

        assertTest(ImageScanLogic.interval(unchangedScans: 0, lowPower: false) == 1.5, "Scans every 1.5s while the screen changes")
        assertTest(ImageScanLogic.interval(unchangedScans: 5, lowPower: false) == 3.0, "Backs off to 3s when the screen is still")
        assertTest(ImageScanLogic.interval(unchangedScans: 50, lowPower: false) == 6.0, "Backs off to 6s when it stays still")
        assertTest(ImageScanLogic.interval(unchangedScans: 0, lowPower: true) == 3.0 && ImageScanLogic.interval(unchangedScans: 50, lowPower: true) == 12.0, "Low Power Mode halves the rate")
        assertTest(ImageScanLogic.ignoredBundleIdentifiers.contains("com.apple.Terminal"), "Terminal is not scanned")

        print("\n🎉 ALL TESTS INCLUDING CINEMA MODE, MATH CHALLENGE AND ADULT BLOCK PASSED SUCCESSFULLY! 🎉\n")
    }
}
