/// A compact, fast set of adult domains, stored as sorted 64-bit hashes (about 8 bytes per domain, so a
/// million-domain list is ~8 MB instead of ~60 MB of strings). Pure Swift (no Foundation) for easy testing.
public struct AdultDomainIndex {
    /// Sorted and de-duplicated.
    public private(set) var hashes: [UInt64]

    public var count: Int { hashes.count }

    public init(hashes unsorted: [UInt64]) {
        var sorted = unsorted
        sorted.sort()
        var unique: [UInt64] = []
        unique.reserveCapacity(sorted.count)
        for value in sorted where unique.last != value { unique.append(value) }
        hashes = unique
    }

    // MARK: - Hashing

    /// FNV-1a, 64-bit. Deterministic across launches (unlike Swift's `Hasher`), so it can be saved to disk.
    @inline(__always)
    static func fnv1a(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    public static func hash(of domain: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in domain.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    // MARK: - Lookup

    /// Mainstream sites that are never treated as adult, even if a list wrongly contains them.
    static let neverBlock: Set<String> = [
        "google.com", "bing.com", "duckduckgo.com", "yahoo.com", "wikipedia.org", "github.com", "apple.com",
        "microsoft.com", "amazon.com", "anthropic.com", "claude.ai", "openai.com", "cloudflare.com",
        "mozilla.org", "brave.com", "stackoverflow.com", "medium.com", "wordpress.com", "blogspot.com",
        "youtube.com", "reddit.com", "twitter.com", "x.com", "instagram.com", "facebook.com", "tiktok.com",
        "discord.com", "telegram.org", "tumblr.com", "pinterest.com", "imgur.com", "localhost"
    ]

    public func contains(hash: UInt64) -> Bool {
        var low = 0
        var high = hashes.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = hashes[mid]
            if value == hash { return true }
            if value < hash { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    /// True when the host, or any parent domain of it (but not a bare TLD), is in the index.
    public func containsHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count >= 2 else { return false }
        for start in 0..<(labels.count - 1) {
            let suffix = labels[start...].joined(separator: ".")
            if AdultDomainIndex.neverBlock.contains(suffix) { return false }
            if contains(hash: AdultDomainIndex.hash(of: suffix)) { return true }
        }
        return false
    }

    // MARK: - Parsing

    /// Reads a blocklist (hosts format `0.0.0.0 example.com`, or one bare domain per line) straight from
    /// its bytes into hashes, ignoring comments, blank lines, IP addresses and `localhost`.
    public static func parse(_ data: [UInt8]) -> [UInt64] {
        var result: [UInt64] = []
        result.reserveCapacity(data.count / 18)
        let count = data.count

        data.withUnsafeBufferPointer { bytes in
            var lineStart = 0
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count && bytes[lineEnd] != 0x0A { lineEnd += 1 }

                // Cut at a comment marker, then trim trailing whitespace.
                var end = lineStart
                while end < lineEnd && bytes[end] != 0x23 { end += 1 }
                while end > lineStart, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 || bytes[end - 1] == 0x0D {
                    end -= 1
                }

                // The domain is the last whitespace-separated token on the line.
                var start = end
                while start > lineStart, bytes[start - 1] != 0x20 && bytes[start - 1] != 0x09 { start -= 1 }
                if end - start >= 2, bytes[start] == 0x2A, bytes[start + 1] == 0x2E { start += 2 }   // "*."

                if let hash = hashIfDomain(bytes, start, end) { result.append(hash) }
                lineStart = lineEnd + 1
            }
        }
        return result
    }

    /// Hashes `bytes[start..<end]` (lower-cased) when it looks like a real domain name: letters, digits,
    /// `-`, `_`, at least one dot, not an IP address, not `localhost`.
    private static func hashIfDomain(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> UInt64? {
        guard end > start, end - start <= 253 else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var hasDot = false
        var hasLetter = false
        for index in start..<end {
            var byte = bytes[index]
            switch byte {
            case 0x41...0x5A:                       // A-Z -> a-z
                byte += 0x20
                hasLetter = true
            case 0x61...0x7A:
                hasLetter = true
            case 0x30...0x39, 0x2D, 0x5F:           // 0-9 - _
                break
            case 0x2E:
                hasDot = true
            default:
                return nil
            }
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        guard hasDot, hasLetter else { return nil }  // no dot: localhost etc.; no letter: an IP address
        return hash
    }

    // MARK: - Saving

    /// Raw little-endian hash array, as written to the cache file.
    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hashes.count * 8)
        for value in hashes {
            for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        }
        return out
    }

    public init(serialized bytes: [UInt8]) {
        var values: [UInt64] = []
        values.reserveCapacity(bytes.count / 8)
        var index = 0
        while index + 8 <= bytes.count {
            var value: UInt64 = 0
            for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << UInt64(offset * 8) }
            values.append(value)
            index += 8
        }
        self.init(hashes: values)
    }
}
