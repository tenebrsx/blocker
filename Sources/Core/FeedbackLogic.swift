import Foundation

/// What the image scanner learns from the user's corrections. Every image block (and every look the scanner held
/// back) can be marked "explicit" or "not explicit" in the Block Log. The scanner keeps a fingerprint of that part
/// of the screen (a list of numbers from macOS's picture feature print, not the picture) with the answer. When a
/// later look is very close to one the user has marked, the scanner follows what the user said.
///
/// This is a memory, not retraining: it recognises the same picture or scene again (a video that keeps scoring
/// 100% although it is a finger and some food), not every picture of that kind. Measured on harmless pictures, the
/// same picture resized, cropped or brightened scored 0.88 to 1.00 against itself, but two screenshots of the same
/// app's window (similar chrome, different content) scored up to 0.92, so a match has to be very close.
/// Pure Swift apart from Foundation, so it can be unit-tested; `PictureFingerprint` and `FeedbackStore` do the
/// system and file work.
public enum FeedbackLogic {

    /// The user's answer about what a picture really was.
    public enum Label: String, Codable, Equatable {
        case explicit
        case notExplicit
    }

    /// A fingerprint the user has answered about.
    public struct Memory: Equatable {
        public let id: String
        public let label: Label
        public let revision: Int
        /// Normalised to length 1, so similarity is a plain dot product.
        public let vector: [Float]

        public init(id: String, label: Label, revision: Int, vector: [Float]) {
            self.id = id
            self.label = label
            self.revision = revision
            self.vector = FeedbackLogic.normalised(vector)
        }
    }

    public struct Match: Equatable {
        public let label: Label
        public let similarity: Double
        public let id: String
    }

    /// Cosine similarity at or above this counts as the same picture again.
    public static let matchThreshold = 0.96

    /// If the closest memory of the other kind is nearly as close, the memories disagree and none is followed.
    public static let ambiguityMargin = 0.01

    /// Fingerprints that have no answer yet are kept for this many looks (answered ones are never dropped).
    public static let maxUnansweredPrints = 300

    // MARK: - Fingerprints

    public static func normalised(_ vector: [Float]) -> [Float] {
        var sum: Double = 0
        for value in vector { sum += Double(value) * Double(value) }
        let length = sum.squareRoot()
        guard length > 0 else { return vector }
        return vector.map { Float(Double($0) / length) }
    }

    /// Cosine similarity, -1...1; 0 when the vectors cannot be compared.
    public static func similarity(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        let a = normalised(first), b = normalised(second)
        var dot: Double = 0
        for index in 0..<a.count { dot += Double(a[index]) * Double(b[index]) }
        return dot
    }

    /// The memory this look is close enough to, or nil when none is, or when memories of both kinds are about
    /// equally close.
    public static func bestMatch(vector: [Float], revision: Int, memories: [Memory]) -> Match? {
        let probe = normalised(vector)
        var best: [Label: Match] = [:]
        for memory in memories where memory.revision == revision && memory.vector.count == probe.count {
            var dot: Double = 0
            for index in 0..<probe.count { dot += Double(probe[index]) * Double(memory.vector[index]) }
            if dot > (best[memory.label]?.similarity ?? -2) { best[memory.label] = Match(label: memory.label, similarity: dot, id: memory.id) }
        }
        let candidates = best.values.filter { $0.similarity >= matchThreshold }.sorted { $0.similarity > $1.similarity }
        guard let top = candidates.first else { return nil }
        if let other = candidates.dropFirst().first, top.similarity - other.similarity < ambiguityMargin { return nil }
        return top
    }

    // MARK: - Storing fingerprints

    /// A fingerprint as text: its normalised values as little-endian Float32, base64.
    public static func encode(_ vector: [Float]) -> String {
        var data = Data(capacity: vector.count * 4)
        for value in normalised(vector) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    public static func decode(_ text: String) -> [Float]? {
        guard let data = Data(base64Encoded: text), data.count % 4 == 0, !data.isEmpty else { return nil }
        var result: [Float] = []
        result.reserveCapacity(data.count / 4)
        for offset in stride(from: 0, to: data.count, by: 4) {
            let bits = data.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            result.append(Float(bitPattern: bits))
        }
        return result
    }

    /// Lines of the fingerprint file to keep: every one the user has answered about, plus the newest
    /// `maxUnanswered` of the rest. `idOf` reads the event id from a line.
    public static func keptPrintLines(_ lines: [String], answered: Set<String>, maxUnanswered: Int = maxUnansweredPrints, idOf: (String) -> String?) -> [String] {
        var unanswered = 0
        var keep = [Bool](repeating: false, count: lines.count)
        for index in lines.indices.reversed() {
            if let id = idOf(lines[index]), answered.contains(id) {
                keep[index] = true
            } else if unanswered < maxUnanswered {
                keep[index] = true
                unanswered += 1
            }
        }
        return lines.indices.filter { keep[$0] }.map { lines[$0] }
    }

    // MARK: - How right the scanner has been

    public struct Accuracy: Equatable {
        /// Blocks the user marked explicit (right) and not explicit (wrong).
        public var blocksRight = 0
        public var blocksWrong = 0
        /// Looks the scanner left open that the user marked explicit (missed) and not explicit (rightly left alone).
        public var missed = 0
        public var rightlyLeftOpen = 0

        public var reviewed: Int { blocksRight + blocksWrong + missed + rightlyLeftOpen }

        /// Of the blocks the user reviewed, the share that were right. Nil until one is reviewed.
        public var blockPrecision: Double? {
            blocksRight + blocksWrong == 0 ? nil : Double(blocksRight) / Double(blocksRight + blocksWrong)
        }
    }

    public static func accuracy(events: [BlockEvent], labels: [String: Label]) -> Accuracy {
        var result = Accuracy()
        for event in events where event.kind == .image {
            guard let label = labels[event.id] else { continue }
            switch (event.outcome, label) {
            case (.blocked, .explicit): result.blocksRight += 1
            case (.blocked, .notExplicit): result.blocksWrong += 1
            case (.nearMiss, .explicit): result.missed += 1
            case (.nearMiss, .notExplicit): result.rightlyLeftOpen += 1
            }
        }
        return result
    }
}
