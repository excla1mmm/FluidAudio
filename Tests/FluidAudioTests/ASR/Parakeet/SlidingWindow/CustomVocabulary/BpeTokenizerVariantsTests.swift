import XCTest

@testable import FluidAudio

/// Tests for the dual SentencePiece tokenization variants used by CTC
/// keyword spotting (with and without leading `▁` word-boundary marker).
///
/// These tests load the real `parakeet-ctc-110m-coreml/tokenizer.json` if
/// it is present in the user's Application Support directory and skip
/// otherwise. They are not part of CITests.
final class BpeTokenizerVariantsTests: XCTestCase {

    private struct GoldenFixture: Decodable {
        struct Case: Decodable {
            let text: String
            let ids: [Int]
        }

        let cases: [Case]
    }

    private var goldenFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../Resources/parakeet-v3-tokenizer-golden.json")
            .standardizedFileURL
    }

    private func loadGoldenTokenizer(
        normalization: BpeNormalization = .parakeetV3CaseSensitive
    ) throws -> (BpeTokenizer, GoldenFixture) {
        let data = try Data(contentsOf: goldenFixtureURL)
        let fixture = try JSONDecoder().decode(GoldenFixture.self, from: data)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudio-BpeTokenizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("tokenizer.json"), options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return (try BpeTokenizer.load(from: directory, normalization: normalization), fixture)
    }

    /// Path to the CTC tokenizer that ships with the parakeet-ctc-110m model.
    private var tokenizerDir: URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let dir =
            appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
        let tokenizer = dir.appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: tokenizer.path) ? dir : nil
    }

    private func loadTokenizer() throws -> BpeTokenizer? {
        guard let dir = tokenizerDir else { return nil }
        return try BpeTokenizer.load(from: dir)
    }

    func testEncodeWithBoundaryMatchesDefault() throws {
        guard let tok = try loadTokenizer() else {
            throw XCTSkip("parakeet-ctc-110m tokenizer not present locally")
        }
        // Default `encode` should be equivalent to explicit `prependWordBoundary: true`.
        let defaultIds = tok.encode("hello world")
        let withBoundary = tok.encode("hello world", prependWordBoundary: true)
        XCTAssertEqual(defaultIds, withBoundary)
    }

    func testWithoutBoundaryDiffersForLeadingWordToken() throws {
        guard let tok = try loadTokenizer() else {
            throw XCTSkip("parakeet-ctc-110m tokenizer not present locally")
        }
        // Most common words begin with a `▁`-prefixed BPE piece. Stripping
        // the boundary should change the first token at minimum.
        let withBoundary = tok.encode("hello", prependWordBoundary: true)
        let withoutBoundary = tok.encode("hello", prependWordBoundary: false)
        XCTAssertFalse(withBoundary.isEmpty)
        XCTAssertFalse(withoutBoundary.isEmpty)
        XCTAssertNotEqual(
            withBoundary, withoutBoundary,
            "With-boundary and without-boundary tokenizations should differ for a word"
        )
    }

    func testWithoutBoundaryHasNoLeadingBoundaryToken() throws {
        guard let tok = try loadTokenizer() else {
            throw XCTSkip("parakeet-ctc-110m tokenizer not present locally")
        }
        // The without-boundary encoding should never produce more tokens
        // than the with-boundary encoding (the leading `▁` adds at most one).
        let withBoundary = tok.encode("nvidia", prependWordBoundary: true)
        let withoutBoundary = tok.encode("nvidia", prependWordBoundary: false)
        XCTAssertLessThanOrEqual(withoutBoundary.count, withBoundary.count + 1)
        // And the without-boundary form should not start with a token whose
        // ID matches the with-boundary first token (since that token is the
        // `▁`-prefixed piece).
        if withBoundary.count >= 1 && !withoutBoundary.isEmpty {
            // We can't decode to a string without the full tokenizer
            // facade, so we just assert ids differ in their first position.
            // This is the property the rescorer relies on.
            XCTAssertNotEqual(
                withBoundary.first, withoutBoundary.first,
                "First token should differ between boundary variants"
            )
        }
    }

    func testCtcTokenizerEncodeVariantsReturnsBothForWord() async throws {
        guard let dir = tokenizerDir else {
            throw XCTSkip("parakeet-ctc-110m tokenizer not present locally")
        }
        let ctcTokenizer = try await CtcTokenizer.load(from: dir)
        // For typical English words, encodeVariants should return both
        // variants (they differ on the leading token).
        let variants = ctcTokenizer.encodeVariants("nvidia")
        XCTAssertEqual(variants.count, 2, "Expected with- and without-boundary variants")
        XCTAssertNotEqual(variants[0], variants[1])
        // First variant is always the boundary form.
        XCTAssertEqual(variants[0], ctcTokenizer.encode("nvidia"))
        XCTAssertEqual(variants[1], ctcTokenizer.encodeWithoutBoundary("nvidia"))
    }

    func testDefaultNormalizationPreservesExistingLowercasedCTCBehavior() throws {
        let (defaultTokenizer, _) = try loadGoldenTokenizer(normalization: .ctcLowercased)
        XCTAssertEqual(defaultTokenizer.encode("МИКО"), [1033, 386])

        let data = try Data(contentsOf: goldenFixtureURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudio-BpeTokenizer-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("tokenizer.json"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: directory) }

        let implicitDefault = try BpeTokenizer.load(from: directory)
        XCTAssertEqual(implicitDefault.encode("МИКО"), [1033, 386])
    }

    func testParakeetV3CaseSensitiveEncodingMatchesOfficialGoldenIDs() throws {
        let (tokenizer, fixture) = try loadGoldenTokenizer()

        for testCase in fixture.cases {
            XCTAssertEqual(
                tokenizer.encode(testCase.text),
                testCase.ids,
                "Unexpected token IDs for \(testCase.text)"
            )
        }
    }

    func testParakeetV3NormalizesWhitespaceWithoutFoldingCase() throws {
        let (tokenizer, _) = try loadGoldenTokenizer()
        XCTAssertEqual(tokenizer.encode("  Мико\t  поддержка  "), [3153, 386, 1821, 4811, 7951, 421])
        XCTAssertNotEqual(tokenizer.encode("МИКО"), tokenizer.encode("Мико"))
        XCTAssertNotEqual(tokenizer.encode("Мико"), tokenizer.encode("мико"))
    }

    func testParakeetV3KeepsPunctuationAndUsesUnknownTokenID() throws {
        let (tokenizer, _) = try loadGoldenTokenizer()
        XCTAssertEqual(tokenizer.encode("IP-телефония"), [380, 7946, 7918, 389, 511, 8022, 7885, 1040])
        XCTAssertEqual(tokenizer.encode("мир!"), [1033, 7896, 8020])
        XCTAssertEqual(tokenizer.encode("🙂"), [7863, 0])
    }

    func testParakeetV3TokenIDsAreDeterministicAcrossLoads() throws {
        let (first, fixture) = try loadGoldenTokenizer()
        let (second, _) = try loadGoldenTokenizer()

        XCTAssertEqual(
            fixture.cases.map { first.encode($0.text) },
            fixture.cases.map { second.encode($0.text) }
        )
    }

    func testMergeRanksUseIndexedEarliestRuleLookup() throws {
        let (tokenizer, _) = try loadGoldenTokenizer()

        XCTAssertEqual(tokenizer.mergeRank(first: "▁", second: "М"), 12)
        XCTAssertNil(tokenizer.mergeRank(first: "not", second: "present"))
    }

    func testMalformedMergeEntryIsRejected() throws {
        let data = try Data(contentsOf: goldenFixtureURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var model = try XCTUnwrap(json["model"] as? [String: Any])
        model["merges"] = [["missing-second-token"]]
        json["model"] = model

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudio-BpeTokenizer-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformed = try JSONSerialization.data(withJSONObject: json)
        try malformed.write(to: directory.appendingPathComponent("tokenizer.json"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try BpeTokenizer.load(from: directory, normalization: .parakeetV3CaseSensitive)
        ) { error in
            guard case BpeTokenizer.Error.invalidJSON = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }
}
