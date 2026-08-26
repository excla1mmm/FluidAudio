import XCTest

@testable import FluidAudio

final class TdtPhraseRescorerTests: XCTestCase {
    func testRescoringSelectsOnlyFromProvidedTop64Candidates() throws {
        let config = PhraseBiasingConfig(
            tree: try PhraseBoostingTree(tokenSequences: [[99]]),
            alpha: 1,
            maximumTokenBoost: 10
        )
        let ids = Array(0...64) + [99]
        let logits = Array(repeating: Float(0), count: ids.count)

        let result = TdtPhraseRescorer.selectCandidate(
            topKIds: ids,
            topKLogits: logits,
            blankId: 64,
            state: config.tree.rootState,
            config: config
        )

        XCTAssertEqual(result?.token, 0)
    }

    func testPositiveAndNegativeScoreDeltasAreClamped() throws {
        let tree = try PhraseBoostingTree(
            tokenSequences: [[1, 2, 3]], contextScore: 5, depthScaling: 2)
        let config = PhraseBiasingConfig(tree: tree, alpha: 3, maximumTokenBoost: 0.75)

        let positive = TdtPhraseRescorer.selectCandidate(
            topKIds: [1, 9], topKLogits: [0, 0.5], blankId: 10,
            state: tree.rootState, config: config)
        XCTAssertEqual(positive?.token, 1)
        XCTAssertEqual(positive?.addedScore ?? 0, 0.75, accuracy: 0.0001)

        let one = tree.transition(from: tree.rootState, token: 1)
        let two = tree.transition(from: one.state, token: 2)
        let negative = TdtPhraseRescorer.selectCandidate(
            topKIds: [9], topKLogits: [0], blankId: 10,
            state: two.state, config: config)
        XCTAssertEqual(negative?.addedScore ?? 0, -0.75, accuracy: 0.0001)
    }

    func testBlankRemainsInCompetitionAndTiesUseOriginalCandidateOrder() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1]])
        let config = PhraseBiasingConfig(tree: tree, alpha: 0.1, maximumTokenBoost: 1)

        let blankWins = TdtPhraseRescorer.selectCandidate(
            topKIds: [7, 1], topKLogits: [2, 0], blankId: 7,
            state: tree.rootState, config: config)
        XCTAssertEqual(blankWins?.token, 7)

        let tie = TdtPhraseRescorer.selectCandidate(
            topKIds: [4, 3], topKLogits: [1, 1], blankId: 7,
            state: tree.rootState, config: config)
        XCTAssertEqual(tie?.token, 4)
    }

    func testBlankCommitDoesNotChangeStateOrMetrics() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1]])
        let config = PhraseBiasingConfig(tree: tree, alpha: 1, maximumTokenBoost: 2)
        var state = tree.rootState
        var metrics = PhraseBiasingMetrics()

        TdtPhraseRescorer.commit(
            token: 7, blankId: 7, addedScore: 0,
            state: &state, metrics: &metrics, config: config)

        XCTAssertEqual(state, tree.rootState)
        XCTAssertEqual(metrics, PhraseBiasingMetrics())
    }

    func testCommitTracksBoostedDecisionsAndAllCompletedOverlaps() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1, 2, 1], [2, 1]])
        let config = PhraseBiasingConfig(tree: tree, alpha: 1, maximumTokenBoost: 5)
        var state = tree.rootState
        var metrics = PhraseBiasingMetrics()

        for token in [1, 2, 1] {
            let selection = try XCTUnwrap(
                TdtPhraseRescorer.selectCandidate(
                    topKIds: [token], topKLogits: [0], blankId: 9,
                    state: state, config: config))
            TdtPhraseRescorer.commit(
                token: selection.token, blankId: 9, addedScore: selection.addedScore,
                state: &state, metrics: &metrics, config: config)
        }

        XCTAssertEqual(metrics.boostedTokenDecisions, 3)
        XCTAssertEqual(metrics.completedPhrases, 2)
    }

    func testMetricsEncodingContainsCountersOnly() throws {
        let metrics = PhraseBiasingMetrics(boostedTokenDecisions: 4, completedPhrases: 2)
        let encoded = try JSONEncoder().encode(metrics)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["boostedTokenDecisions", "completedPhrases"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("vocabulary"))
    }

    func testMalformedCandidateArraysReturnNoSelection() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1]])
        let config = PhraseBiasingConfig(tree: tree, alpha: 1, maximumTokenBoost: 1)

        XCTAssertNil(
            TdtPhraseRescorer.selectCandidate(
                topKIds: [], topKLogits: [], blankId: 9, state: tree.rootState, config: config))
        XCTAssertNil(
            TdtPhraseRescorer.selectCandidate(
                topKIds: [1], topKLogits: [], blankId: 9, state: tree.rootState, config: config))
    }
}
