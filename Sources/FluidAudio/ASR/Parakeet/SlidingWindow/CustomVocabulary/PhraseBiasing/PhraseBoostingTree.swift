import Foundation

public enum PhraseBoostingTreeError: Error, Equatable, Sendable {
    case noTokenSequences
    case emptyTokenSequence
    case invalidTokenID(Int)
    case invalidContextScore
    case invalidDepthScaling
}

/// A lightweight position in a ``PhraseBoostingTree``.
public struct PhraseBoostingState: Equatable, Sendable {
    fileprivate let nodeIndex: Int
}

struct PhraseBoostingTransition: Sendable {
    let state: PhraseBoostingState
    let scoreDelta: Float
    let completedPhrases: Int
}

/// Immutable Aho-Corasick phrase graph with NeMo-compatible score deltas.
public struct PhraseBoostingTree: Sendable {
    private struct Node: Sendable {
        var arcs: [Int: Int] = [:]
        var failure = 0
        var nodeScore: Float = 0
        var isEnd = false
        var completedOutputs = 0
    }

    private let nodes: [Node]
    let phraseCount: Int

    public var rootState: PhraseBoostingState {
        PhraseBoostingState(nodeIndex: 0)
    }

    public init(
        tokenSequences: [[Int]],
        contextScore: Float = 1,
        depthScaling: Float = 2
    ) throws {
        guard !tokenSequences.isEmpty else {
            throw PhraseBoostingTreeError.noTokenSequences
        }
        guard contextScore.isFinite, contextScore > 0 else {
            throw PhraseBoostingTreeError.invalidContextScore
        }
        guard depthScaling.isFinite, depthScaling >= 1 else {
            throw PhraseBoostingTreeError.invalidDepthScaling
        }
        for sequence in tokenSequences {
            guard !sequence.isEmpty else {
                throw PhraseBoostingTreeError.emptyTokenSequence
            }
            if let invalid = sequence.first(where: { $0 < 0 }) {
                throw PhraseBoostingTreeError.invalidTokenID(invalid)
            }
        }

        let uniqueSequences = Array(Set(tokenSequences)).sorted(by: Self.sequencePrecedes)
        var buildingNodes = [Node()]

        for sequence in uniqueSequences {
            var currentIndex = 0
            for (depth, token) in sequence.enumerated() {
                if let existing = buildingNodes[currentIndex].arcs[token] {
                    currentIndex = existing
                    continue
                }

                let tokenScore: Float
                if depth == 0 {
                    tokenScore = contextScore
                } else {
                    tokenScore = contextScore * depthScaling + logf(Float(depth + 1))
                }
                let nextIndex = buildingNodes.count
                let nextNode = Node(
                    nodeScore: buildingNodes[currentIndex].nodeScore + tokenScore)
                buildingNodes.append(nextNode)
                buildingNodes[currentIndex].arcs[token] = nextIndex
                currentIndex = nextIndex
            }
            buildingNodes[currentIndex].isEnd = true
        }

        var queue: [Int] = []
        for token in buildingNodes[0].arcs.keys.sorted() {
            guard let child = buildingNodes[0].arcs[token] else { continue }
            buildingNodes[child].failure = 0
            buildingNodes[child].completedOutputs = buildingNodes[child].isEnd ? 1 : 0
            queue.append(child)
        }

        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            for token in buildingNodes[current].arcs.keys.sorted() {
                guard let child = buildingNodes[current].arcs[token] else { continue }
                var fallback = buildingNodes[current].failure
                while fallback != 0 && buildingNodes[fallback].arcs[token] == nil {
                    fallback = buildingNodes[fallback].failure
                }
                if let suffix = buildingNodes[fallback].arcs[token], suffix != child {
                    buildingNodes[child].failure = suffix
                } else {
                    buildingNodes[child].failure = 0
                }
                let ownCompletion = buildingNodes[child].isEnd ? 1 : 0
                let failure = buildingNodes[child].failure
                buildingNodes[child].completedOutputs =
                    ownCompletion + buildingNodes[failure].completedOutputs
                queue.append(child)
            }
        }

        nodes = buildingNodes
        phraseCount = uniqueSequences.count
    }

    func transition(from state: PhraseBoostingState, token: Int) -> PhraseBoostingTransition {
        var current = nodes.indices.contains(state.nodeIndex) ? state.nodeIndex : 0
        var scoreDelta: Float = 0

        while nodes[current].arcs[token] == nil && current != 0 {
            let fallback = nodes[current].failure
            if !nodes[current].isEnd {
                scoreDelta += nodes[fallback].nodeScore - nodes[current].nodeScore
            }
            current = fallback
        }

        if let next = nodes[current].arcs[token] {
            scoreDelta += nodes[next].nodeScore - nodes[current].nodeScore
            return PhraseBoostingTransition(
                state: PhraseBoostingState(nodeIndex: next),
                scoreDelta: scoreDelta,
                completedPhrases: nodes[next].completedOutputs
            )
        }

        return PhraseBoostingTransition(
            state: rootState,
            scoreDelta: scoreDelta,
            completedPhrases: 0
        )
    }

    var debugSnapshot: String {
        nodes.enumerated().map { index, node in
            let arcs = node.arcs.keys.sorted().map { token in
                "\(token):\(node.arcs[token] ?? -1)"
            }.joined(separator: ",")
            return "\(index)|\(node.failure)|\(node.nodeScore)|\(node.isEnd)|\(node.completedOutputs)|\(arcs)"
        }.joined(separator: "\n")
    }

    private static func sequencePrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }
}
