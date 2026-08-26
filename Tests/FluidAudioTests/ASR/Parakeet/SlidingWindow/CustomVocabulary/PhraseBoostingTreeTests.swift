import XCTest

@testable import FluidAudio

final class PhraseBoostingTreeTests: XCTestCase {
    func testRejectsMissingAndInvalidTokenSequences() {
        XCTAssertThrowsError(try PhraseBoostingTree(tokenSequences: [])) { error in
            XCTAssertEqual(error as? PhraseBoostingTreeError, .noTokenSequences)
        }
        XCTAssertThrowsError(try PhraseBoostingTree(tokenSequences: [[]])) { error in
            XCTAssertEqual(error as? PhraseBoostingTreeError, .emptyTokenSequence)
        }
        XCTAssertThrowsError(try PhraseBoostingTree(tokenSequences: [[1, -1]])) { error in
            XCTAssertEqual(error as? PhraseBoostingTreeError, .invalidTokenID(-1))
        }
    }

    func testRejectsInvalidScoringParameters() {
        XCTAssertThrowsError(try PhraseBoostingTree(tokenSequences: [[1]], contextScore: 0))
        XCTAssertThrowsError(try PhraseBoostingTree(tokenSequences: [[1]], depthScaling: 0.5))
    }

    func testDuplicatePhrasesAreDeduplicated() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1, 2], [1, 2], [1, 2]])
        let first = tree.transition(from: tree.rootState, token: 1)
        let second = tree.transition(from: first.state, token: 2)

        XCTAssertEqual(second.completedPhrases, 1)
        XCTAssertEqual(tree.phraseCount, 1)
    }

    func testPrefixFailurePaysBackoffDeltaBeforeStartingNewMatch() throws {
        let tree = try PhraseBoostingTree(
            tokenSequences: [[1, 2, 3], [1, 2, 4], [3]],
            contextScore: 1,
            depthScaling: 1
        )
        let one = tree.transition(from: tree.rootState, token: 1)
        let two = tree.transition(from: one.state, token: 2)
        let fallback = tree.transition(from: two.state, token: 1)

        XCTAssertEqual(one.scoreDelta, 1, accuracy: 0.0001)
        XCTAssertEqual(two.scoreDelta, 1 + logf(2), accuracy: 0.0001)
        XCTAssertEqual(fallback.scoreDelta, -(1 + logf(2)), accuracy: 0.0001)
    }

    func testSuffixFallbackCompletesOverlappingPhrase() throws {
        let tree = try PhraseBoostingTree(tokenSequences: [[1, 2, 1], [2, 1]])
        let one = tree.transition(from: tree.rootState, token: 1)
        let two = tree.transition(from: one.state, token: 2)
        let overlapping = tree.transition(from: two.state, token: 1)

        XCTAssertEqual(overlapping.completedPhrases, 2)

        let nextTwo = tree.transition(from: overlapping.state, token: 2)
        let nextOne = tree.transition(from: nextTwo.state, token: 1)
        XCTAssertEqual(nextOne.completedPhrases, 2)
    }

    func testCompletedPhraseStartsNewMatchWithoutRollbackPenalty() throws {
        let tree = try PhraseBoostingTree(
            tokenSequences: [[3], [1, 2]], contextScore: 1, depthScaling: 1)
        let completed = tree.transition(from: tree.rootState, token: 3)
        let restarted = tree.transition(from: completed.state, token: 1)

        XCTAssertEqual(completed.completedPhrases, 1)
        XCTAssertEqual(restarted.scoreDelta, 1, accuracy: 0.0001)
    }

    func testConstructionIsDeterministicAcrossInputOrder() throws {
        let first = try PhraseBoostingTree(tokenSequences: [[8, 2], [1], [8, 1], [2, 1]])
        let second = try PhraseBoostingTree(tokenSequences: [[2, 1], [8, 1], [1], [8, 2]])

        XCTAssertEqual(first.debugSnapshot, second.debugSnapshot)
    }
}
