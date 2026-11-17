import Foundation

/// Where the user's corrections and the fingerprints they refer to are kept, in
/// `~/Library/Application Support/WordBlocker/`:
/// - `labels.json`: for each Block Log entry the user has marked, "explicit" or "not explicit";
/// - `prints.jsonl`: the fingerprint (numbers, not a picture) of the flagged part of the screen, per entry.
/// It stays on this Mac. Nothing here can be turned back into a picture.
public final class FeedbackStore {
    public static let shared = FeedbackStore()

    /// Tests point this at a temporary folder.
    public static var directoryOverride: URL?

    public static var directory: URL {
        if let override = directoryOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordBlocker", isDirectory: true)
    }
    public static var labelsURL: URL { directory.appendingPathComponent("labels.json") }
    public static var printsURL: URL { directory.appendingPathComponent("prints.jsonl") }

    private struct StoredLabel: Codable {
        var label: FeedbackLogic.Label
        var date: Date
    }

    private struct StoredPrint: Codable {
        var id: String
        var revision: Int
        var data: String
    }

    private let queue = DispatchQueue(label: "com.wordblocker.feedback")
    private var cachedMemories: [FeedbackLogic.Memory]?

    private init() {}

    // MARK: - Reading

    private func readLabels() -> [String: StoredLabel] {
        guard let data = try? Data(contentsOf: FeedbackStore.labelsURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: StoredLabel].self, from: data)) ?? [:]
    }

    /// The user's answer for each Block Log entry they have marked.
    public func labels() -> [String: FeedbackLogic.Label] {
        queue.sync { readLabels().mapValues { $0.label } }
    }

    /// Every fingerprint the user has answered about, ready to compare with. Cached; a change reloads it.
    public func memories() -> [FeedbackLogic.Memory] {
        queue.sync {
            if let cached = cachedMemories { return cached }
            let labels = readLabels()
            let text = (try? String(contentsOf: FeedbackStore.printsURL, encoding: .utf8)) ?? ""
            let decoder = JSONDecoder()
            var found: [FeedbackLogic.Memory] = []
            for line in text.split(separator: "\n") {
                guard let stored = try? decoder.decode(StoredPrint.self, from: Data(line.utf8)), let answer = labels[stored.id],
                      let vector = FeedbackLogic.decode(stored.data) else { continue }
                found.append(FeedbackLogic.Memory(id: stored.id, label: answer.label, revision: stored.revision, vector: vector))
            }
            cachedMemories = found
            return found
        }
    }

    // MARK: - Writing

    /// Keeps the fingerprint of the flagged part of the screen for Block Log entry `eventID`, so that a later
    /// answer about that entry can teach the scanner. Never blocks the caller.
    public func recordPrint(eventID: String, revision: Int, vector: [Float]) {
        let stored = StoredPrint(id: eventID, revision: revision, data: FeedbackLogic.encode(vector))
        guard let data = try? JSONEncoder().encode(stored), let line = String(data: data, encoding: .utf8) else { return }
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: FeedbackStore.directory, withIntermediateDirectories: true)
            let existing = ((try? String(contentsOf: FeedbackStore.printsURL, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            let answered = Set(self.readLabels().keys)
            let kept = FeedbackLogic.keptPrintLines(existing + [line], answered: answered) { raw in
                (try? JSONDecoder().decode(StoredPrint.self, from: Data(raw.utf8)))?.id
            }
            try? (kept.joined(separator: "\n") + "\n").write(to: FeedbackStore.printsURL, atomically: true, encoding: .utf8)
            self.cachedMemories = nil
        }
    }

    /// Records the user's answer for an entry (or removes it with nil). Posts `feedbackChanged` on the main thread.
    public func setLabel(_ label: FeedbackLogic.Label?, eventID: String) {
        queue.async {
            var labels = self.readLabels()
            if let label = label {
                labels[eventID] = StoredLabel(label: label, date: Date())
            } else {
                labels.removeValue(forKey: eventID)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: FeedbackStore.directory, withIntermediateDirectories: true)
            if let data = try? encoder.encode(labels) { try? data.write(to: FeedbackStore.labelsURL, options: .atomic) }
            self.cachedMemories = nil
            DispatchQueue.main.async { NotificationCenter.default.post(name: .feedbackChanged, object: nil) }
        }
    }
}

public extension Notification.Name {
    /// Posted on the main thread after the user marks a Block Log entry.
    static let feedbackChanged = Notification.Name("WordBlocker.FeedbackChanged")
}
