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

    /// The tuning trace (every scan's scores, when `WordBlocker.ScanTrace` is on) goes to its own file so its
    /// volume cannot push real blocks out of `blocks.log`.
    public static var traceFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("scan-trace.log")
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
    public static func record(_ reason: String, _ detail: String, trace: Bool = false) {
        let newLine = line(date: Date(), reason: reason, detail: detail) + "\n"
        queue.async {
            let url = trace ? traceFileURL : fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = trimmed(existing + newLine, maxBytes: maxBytes)
            try? updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Structured events (what the Block Log window shows)

    /// One JSON object per line, oldest first: `~/Library/Application Support/WordBlocker/blocks.jsonl`.
    public static var eventsFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("blocks.jsonl")
    }

    /// The newest this many events are kept.
    public static let maxEvents = 2000

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Events from lines of `blocks.jsonl`; lines that cannot be read are skipped.
    public static func events(fromJSONLines text: String) -> [BlockEvent] {
        let decoder = decoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(BlockEvent.self, from: Data($0.utf8)) }
    }

    /// The newest `maxEvents` lines of a JSON-lines file.
    public static func trimmedLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n") + "\n"
    }

    /// First run with the structured log: turns what the older plain-text `blocks.log` holds into events, so
    /// earlier blocks still show in the window. (Runs on `queue`.)
    private static func migrateLegacyIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: eventsFileURL.path) else { return }
        let old = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let encoder = encoder()
        let lines = old.split(separator: "\n").compactMap { BlockEvent.legacy(line: String($0)) }
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? manager.createDirectory(at: eventsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: eventsFileURL, atomically: true, encoding: .utf8)
    }

    /// Records a block (or near miss): one JSON line for the window and one readable line in `blocks.log`.
    /// Never blocks the caller and never throws. Posts `Notification.Name.blockLogChanged` when it is written.
    public static func record(_ event: BlockEvent) {
        let textLine = line(date: event.date, reason: event.kind == .image ? "image-scanner" : "website", detail: event.logLine) + "\n"
        guard let data = try? encoder().encode(event), let json = String(data: data, encoding: .utf8) else { return }
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: eventsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            migrateLegacyIfNeeded()
            let existingEvents = (try? String(contentsOf: eventsFileURL, encoding: .utf8)) ?? ""
            let events = trimmedLines(existingEvents + json + "\n", maxLines: maxEvents)
            try? events.write(to: eventsFileURL, atomically: true, encoding: .utf8)

            let existingText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            try? trimmed(existingText + textLine, maxBytes: maxBytes).write(to: fileURL, atomically: true, encoding: .utf8)

            DispatchQueue.main.async { NotificationCenter.default.post(name: .blockLogChanged, object: nil) }
        }
    }

    /// Every recorded event, newest first.
    public static func loadEvents() -> [BlockEvent] {
        queue.sync {
            migrateLegacyIfNeeded()
            let text = (try? String(contentsOf: eventsFileURL, encoding: .utf8)) ?? ""
            return Array(events(fromJSONLines: text).reversed())
        }
    }
}

public extension Notification.Name {
    /// Posted on the main thread after a block is written to the log.
    static let blockLogChanged = Notification.Name("WordBlocker.BlockLogChanged")
}
