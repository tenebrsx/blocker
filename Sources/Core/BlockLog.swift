import Foundation

/// A plain-text record of every time Word Blocker closed or covered something, and which check did it
/// (adult site list, adult search, page text, or the screen image scanner and its scores). Without it a
/// surprise block can't be explained afterwards. It stays on this Mac, holds no page text and no
/// screenshots, and records addresses without their query string, so what was searched is not kept.
///
/// File: `~/Library/Application Support/WordBlocker/blocks.log`
public enum BlockLog {
    /// The newest lines are kept once the file grows past this.
    public static let maxBytes = 120_000

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordBlocker", isDirectory: true)
            .appendingPathComponent("blocks.log")
    }

    private static let queue = DispatchQueue(label: "com.wordblocker.blocklog", qos: .utility)

    /// One log line: `2026-11-16 14:42:07  image-scanner  explicit scores=[...] page=google.com/search`.
    public static func line(date: Date, reason: String, detail: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let flatDetail = detail.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\(formatter.string(from: date))  \(reason)  \(flatDetail)"
    }

    /// An address without its scheme, query string or fragment, e.g. `www.google.com/search`.
    public static func describePage(_ address: String?) -> String {
        guard var text = address?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "(address unreadable)"
        }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[text.startIndex..<cut]) }
        return String(text.prefix(100))
    }

    /// The newest whole lines that fit in `maxBytes`.
    public static func trimmed(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var total = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        while total > maxBytes, lines.count > 1 {
            total -= lines.removeFirst().utf8.count + 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends a line. Never blocks the caller and never throws: a log must not be able to break blocking.
    public static func record(_ reason: String, _ detail: String) {
        let newLine = line(date: Date(), reason: reason, detail: detail) + "\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = trimmed(existing + newLine, maxBytes: maxBytes)
            try? updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
