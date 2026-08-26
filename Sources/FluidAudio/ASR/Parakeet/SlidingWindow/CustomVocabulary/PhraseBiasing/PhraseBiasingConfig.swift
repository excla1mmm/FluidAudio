import Foundation

/// Immutable phrase-biasing inputs shared by independent Parakeet decoders.
public struct PhraseBiasingConfig: Sendable {
    public let tree: PhraseBoostingTree
    public let alpha: Float
    public let maximumTokenBoost: Float

    public init(
        tree: PhraseBoostingTree,
        alpha: Float,
        maximumTokenBoost: Float
    ) {
        self.tree = tree
        self.alpha = alpha
        self.maximumTokenBoost = maximumTokenBoost
    }
}

/// Aggregate counters deliberately contain no phrases, token IDs, or transcript text.
public struct PhraseBiasingMetrics: Codable, Equatable, Sendable {
    public let boostedTokenDecisions: Int
    public let completedPhrases: Int

    public init(boostedTokenDecisions: Int = 0, completedPhrases: Int = 0) {
        self.boostedTokenDecisions = boostedTokenDecisions
        self.completedPhrases = completedPhrases
    }
}
