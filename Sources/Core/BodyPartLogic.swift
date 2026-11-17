/// The decisions behind the body-part detector the Block Log uses to say what an image block was about: reading
/// the model's output, removing duplicate boxes, naming the parts, and writing them up. Pure Swift (no Core ML,
/// no Foundation) so it can be unit-tested; `BodyPartDetector` runs the model.
///
/// The detector (NudeNet v3, 320n) is the second opinion. The image model only proposes a block; with the setting
/// on, an explicit body part found here has to confirm it before anything closes. It only looks at the parts of the
/// screen the image model flagged, and the log says what it found.
public enum BodyPartLogic {

    /// The model looks at a square picture this many pixels on a side.
    public static let modelSize = 320

    /// The classes, in the order the model outputs them (also stored in the converted model's metadata).
    public static let labels: [String] = [
        "FEMALE_GENITALIA_COVERED", "FACE_FEMALE", "BUTTOCKS_EXPOSED", "FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED",
        "MALE_BREAST_EXPOSED", "ANUS_EXPOSED", "FEET_EXPOSED", "BELLY_COVERED", "FEET_COVERED", "ARMPITS_COVERED",
        "ARMPITS_EXPOSED", "FACE_MALE", "BELLY_EXPOSED", "MALE_GENITALIA_EXPOSED", "ANUS_COVERED", "FEMALE_BREAST_COVERED",
        "BUTTOCKS_COVERED"
    ]

    /// Plain names for the classes, in the same order.
    static let names: [String] = [
        "female genitals (covered)", "face (female)", "buttocks (exposed)", "female breast (exposed)", "female genitals (exposed)",
        "male chest (exposed)", "anus (exposed)", "feet (exposed)", "belly (covered)", "feet (covered)", "armpits (covered)",
        "armpits (exposed)", "face (male)", "belly (exposed)", "male genitals (exposed)", "anus (covered)", "female breast (covered)",
        "buttocks (covered)"
    ]

    /// The classes that are explicit on their own: exposed genitals, female breast, buttocks and anus. The rest
    /// (faces, belly, armpits, feet, a bare male chest, anything covered) are context.
    static let explicitIndices: Set<Int> = [2, 3, 4, 6, 14]

    /// A box below this confidence is ignored (the detector's own default).
    public static let minimumScore: Float = 0.25

    /// An explicit body part at or above this confidence confirms an image block (the detector's own default
    /// floor is 0.25, and its false alarms are mostly below 0.35).
    public static let confirmationScore: Float = 0.35

    /// Two boxes overlapping more than this are the same thing.
    public static let overlapLimit: Float = 0.45

    public struct Detection: Equatable {
        public let label: Int
        public let score: Float
        /// Centre and size in model pixels (0...320).
        public let centerX: Float
        public let centerY: Float
        public let width: Float
        public let height: Float

        public init(label: Int, score: Float, centerX: Float, centerY: Float, width: Float, height: Float) {
            self.label = label
            self.score = score
            self.centerX = centerX
            self.centerY = centerY
            self.width = width
            self.height = height
        }

        public var name: String { label >= 0 && label < BodyPartLogic.names.count ? BodyPartLogic.names[label] : "unknown" }
        public var isExplicit: Bool { BodyPartLogic.explicitIndices.contains(label) }
    }

    // MARK: - Reading the model's output

    /// The model's output is a table with one column per candidate box: four rows (centre x, centre y, width,
    /// height) then one row of scores per class. `values` holds it row after row, `anchors` is the number of
    /// columns (2100 for a 320 pixel picture). Returns the boxes that score at least `minimumScore`, one per
    /// candidate, best class only, strongest first, with duplicates removed.
    public static func decode(_ values: [Float], anchors: Int, minimumScore: Float = BodyPartLogic.minimumScore) -> [Detection] {
        let classCount = labels.count
        let rows = 4 + classCount
        guard anchors > 0, values.count >= rows * anchors else { return [] }

        var candidates: [Detection] = []
        for anchor in 0..<anchors {
            var best = 0
            var bestScore: Float = -1
            for index in 0..<classCount {
                let score = values[(4 + index) * anchors + anchor]
                if score > bestScore {
                    bestScore = score
                    best = index
                }
            }
            guard bestScore >= minimumScore else { continue }
            candidates.append(Detection(label: best, score: bestScore, centerX: values[anchor], centerY: values[anchors + anchor],
                                        width: values[2 * anchors + anchor], height: values[3 * anchors + anchor]))
        }
        return nonMaximumSuppression(candidates)
    }

    /// Intersection over union of two boxes.
    static func overlap(_ first: Detection, _ second: Detection) -> Float {
        let left = max(first.centerX - first.width / 2, second.centerX - second.width / 2)
        let right = min(first.centerX + first.width / 2, second.centerX + second.width / 2)
        let top = max(first.centerY - first.height / 2, second.centerY - second.height / 2)
        let bottom = min(first.centerY + first.height / 2, second.centerY + second.height / 2)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = first.width * first.height + second.width * second.height - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Strongest first; a box is dropped when a stronger one overlaps it by more than `overlapLimit` (whatever
    /// its class, as the detector's own code does).
    static func nonMaximumSuppression(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for candidate in detections.sorted(by: { $0.score > $1.score }) {
            if !kept.contains(where: { overlap($0, candidate) > overlapLimit }) { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Confirming a block

    /// Whether the detector found an explicit body part (exposed genitals, female breast, buttocks or anus) that it
    /// is sure enough of. A face, a bare chest, a belly or a covered part is not enough on its own.
    public static func confirms(_ detections: [Detection]) -> Bool {
        detections.contains { $0.isExplicit && $0.score >= confirmationScore }
    }

    /// The strongest detection of each kind across several looks (the same part seen in two overlapping crops is
    /// one part), strongest first.
    public static func mergeBest(_ lists: [[Detection]]) -> [Detection] {
        var best: [Int: Detection] = [:]
        for detection in lists.flatMap({ $0 }) where (best[detection.label]?.score ?? -1) < detection.score {
            best[detection.label] = detection
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }
    }

    // MARK: - Writing it up

    public struct Summary: Equatable {
        /// Explicit parts, strongest first: `female breast (exposed) 87%`, with `x2` when found more than once.
        public let explicit: [String]
        /// Everything else the detector saw.
        public let context: [String]
    }

    /// One entry per kind of part, with its best score and how many were found.
    public static func summarise(_ detections: [Detection]) -> Summary {
        var best: [Int: Float] = [:]
        var counts: [Int: Int] = [:]
        for detection in detections {
            best[detection.label] = max(best[detection.label] ?? 0, detection.score)
            counts[detection.label, default: 0] += 1
        }
        func line(_ label: Int) -> String {
            let text = "\(names[label]) \(ImageScanLogic.percent(Double(best[label] ?? 0)))"
            return (counts[label] ?? 1) > 1 ? text + " x\(counts[label] ?? 1)" : text
        }
        let ordered = best.keys.sorted { (best[$0] ?? 0) != (best[$1] ?? 0) ? (best[$0] ?? 0) > (best[$1] ?? 0) : $0 < $1 }
        return Summary(explicit: ordered.filter { explicitIndices.contains($0) }.map(line),
                       context: ordered.filter { !explicitIndices.contains($0) }.map(line))
    }

    /// A sentence for the block's reason.
    public static func sentence(_ summary: Summary) -> String {
        if !summary.explicit.isEmpty {
            let seen = summary.context.isEmpty ? "" : "; also seen: " + summary.context.joined(separator: ", ")
            return "The body-part detector found: " + summary.explicit.joined(separator: ", ") + seen + "."
        }
        if !summary.context.isEmpty {
            return "The body-part detector found no explicit body part in that area; it saw: " + summary.context.joined(separator: ", ") + "."
        }
        return "The body-part detector found no body parts in that area (it is trained on photos, so drawn or unusual pictures are often missed)."
    }
}
