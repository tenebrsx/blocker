import Foundation

/// One arithmetic question with a single integer answer.
public struct MathProblem: Equatable {
    public let prompt: String
    public let answer: Int
}

/// Problem generation and difficulty rules for the "solve math to continue" friction gate.
/// Pure Foundation so the logic can be unit-tested without AppKit.
public enum MathChallenge {
    /// Problems required to quit Word Blocker, disable protection, or loosen a rule.
    public static let strictProblemCount = 10

    /// Mandatory wait before the first problem appears. A pause defeats impulse better than harder math,
    /// because any arithmetic can be solved with a calculator.
    public static let coolOffSeconds: TimeInterval = 30

    /// Social-media unlocks get harder the more you ask for in one day: 5, then 7, then 10.
    /// `unlockNumber` is how many unlocks have already been granted today (0 for the first).
    public static func problemCount(forUnlockNumber unlockNumber: Int) -> Int {
        switch unlockNumber {
        case ..<1: return 5
        case 1: return 7
        default: return 10
        }
    }

    /// Quick mental math: exactly two numbers and one `+` or `−`, e.g. `47 + 28` or `63 − 19`. Nothing in
    /// the problem or its answer goes past two digits (the answer is between 5 and 99), so it never needs
    /// a pen, paper or calculator.
    public static func makeProblem<G: RandomNumberGenerator>(using generator: inout G) -> MathProblem {
        if Bool.random(using: &generator) {
            let a = Int.random(in: 11...88, using: &generator)
            let b = Int.random(in: 6...(99 - a), using: &generator)   // a + b stays at 99 or less
            return MathProblem(prompt: "\(a) + \(b)", answer: a + b)
        }
        let a = Int.random(in: 21...99, using: &generator)
        let b = Int.random(in: 6...(a - 5), using: &generator)        // a − b stays at 5 or more
        return MathProblem(prompt: "\(a) − \(b)", answer: a - b)
    }

    /// The wait before the problems start when unlocking a blocked site: the usual 30 seconds, or none when
    /// the user has turned that wait off in Settings. (Quitting, turning protection off and loosening
    /// settings always keep their wait.)
    public static func siteUnlockCoolOff(waitEnabled: Bool) -> TimeInterval {
        waitEnabled ? coolOffSeconds : 0
    }

    public static func generate<G: RandomNumberGenerator>(count: Int, using generator: inout G) -> [MathProblem] {
        (0..<max(1, count)).map { _ in makeProblem(using: &generator) }
    }

    public static func generate(count: Int) -> [MathProblem] {
        var rng = SystemRandomNumberGenerator()
        return generate(count: count, using: &rng)
    }

    /// Parses what the user typed. Returns nil for empty or non-numeric input (not counted as a wrong answer).
    public static func parseAnswer(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Progress through one challenge. A wrong answer throws away all progress and deals fresh problems,
/// so the only way through is `count` correct answers in a row.
public final class MathChallengeSession {
    public enum Result: Equatable {
        case invalid                    // empty / not a number: ignored
        case correct(finished: Bool)
        case wrong                      // progress reset, new problems dealt
    }

    public let requiredCount: Int
    public private(set) var problems: [MathProblem]
    public private(set) var index = 0

    public init(count: Int, problems: [MathProblem]? = nil) {
        requiredCount = max(1, count)
        self.problems = problems ?? MathChallenge.generate(count: max(1, count))
    }

    public var current: MathProblem? { index < problems.count ? problems[index] : nil }
    public var isComplete: Bool { index >= problems.count }

    public func submit(_ text: String) -> Result {
        guard let problem = current, let value = MathChallenge.parseAnswer(text) else { return .invalid }
        if value == problem.answer {
            index += 1
            return .correct(finished: isComplete)
        }
        restart()
        return .wrong
    }

    public func restart() {
        problems = MathChallenge.generate(count: requiredCount)
        index = 0
    }
}
