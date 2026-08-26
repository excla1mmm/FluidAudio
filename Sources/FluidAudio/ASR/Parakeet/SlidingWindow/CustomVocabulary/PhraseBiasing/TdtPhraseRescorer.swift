import Foundation

struct TdtPhraseRescoringResult: Equatable, Sendable {
    let token: Int
    let logit: Float
    let addedScore: Float
}

/// Deterministic shallow-fusion rescoring for candidates already emitted by the TDT joint model.
enum TdtPhraseRescorer {
    private static let maximumCandidateCount = 64

    static func selectCandidate(
        topKIds: [Int],
        topKLogits: [Float],
        blankId: Int,
        state: PhraseBoostingState,
        config: PhraseBiasingConfig
    ) -> TdtPhraseRescoringResult? {
        guard !topKIds.isEmpty, topKIds.count == topKLogits.count else { return nil }

        let count = min(maximumCandidateCount, topKIds.count)
        var bestIndex = 0
        var bestScore = -Float.infinity
        var bestAddedScore: Float = 0
        let maximumBoost = max(0, config.maximumTokenBoost)

        for index in 0..<count {
            let token = topKIds[index]
            let addedScore: Float
            if token == blankId || !config.alpha.isFinite || !maximumBoost.isFinite {
                addedScore = 0
            } else {
                let transition = config.tree.transition(from: state, token: token)
                addedScore = min(max(config.alpha * transition.scoreDelta, -maximumBoost), maximumBoost)
            }
            let rescored = topKLogits[index] + addedScore
            if rescored > bestScore {
                bestIndex = index
                bestScore = rescored
                bestAddedScore = addedScore
            }
        }

        return TdtPhraseRescoringResult(
            token: topKIds[bestIndex],
            logit: topKLogits[bestIndex],
            addedScore: bestAddedScore
        )
    }

    static func commit(
        token: Int,
        blankId: Int,
        addedScore: Float,
        state: inout PhraseBoostingState,
        metrics: inout PhraseBiasingMetrics,
        config: PhraseBiasingConfig
    ) {
        guard token != blankId else { return }

        let transition = config.tree.transition(from: state, token: token)
        state = transition.state
        metrics = PhraseBiasingMetrics(
            boostedTokenDecisions: metrics.boostedTokenDecisions + (addedScore > 0 ? 1 : 0),
            completedPhrases: metrics.completedPhrases + transition.completedPhrases
        )
    }
}
