@testable import muterCore
import TestingExtensions
import XCTest

final class MuterVisitorTests: MuterTestCase {
    /// These tests judge coverage and `muter:disable` tags, and list the mutants they expect. Their code is full of
    /// `+`s, literals and returned values, whose mutants would say nothing more: those operators' own tests show
    /// they're judged in the same way.
    override var operatorsToDiscoverWith: MutationOperatorList {
        super.operatorsToDiscoverWith.filter {
            ![.arithmeticOperator, .flipBooleanLiteral, .replaceBooleanValue, .replaceReturnValue].contains($0)
        }
    }

    private let sampleFolder = XCTestCase.unusedTemporaryPath()
    private var samplePath: String { sampleFolder + "/sampleWithDisabledCode.swift" }

    override func setUpWithError() throws {
        try super.setUpWithError()

        try FileManager.default.createDirectory(atPath: sampleFolder, withIntermediateDirectories: true)
        addTeardownBlock { [sampleFolder] in try? FileManager.default.removeItem(atPath: sampleFolder) }
    }

    func test_shouldIgnoreSkippedLines() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithDisabledMutations.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(mappings.count, 1)

        XCTAssertEqual(mappings.first?.mutationSchemata.count, 1)
    }

    func test_shouldIgnoreComplexDisablingRules() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithComplexDisableRules.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(mappings.count, 1)

        let ids = mappings.first?.mutationSchemata.map(\.mutationOperatorId)
        XCTAssertEqual(
            ids,
            [.removeSideEffects, .ror, .ror, .swapTernary]
        )
    }

    func test_shouldIgnoreTopLevelDisable() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithTopLevelDisable.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertTrue(mappings.isEmpty)
    }

    func test_ignoreRegionsWithoutCoverage() throws {
        let source = try sourceCode("""
        import Foundation

        public func foo(_ a: Bool, _ b: Bool) -> Bool {
            if a && b {
                return a == b
            }

            return true
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [
                .make(
                    lineStart: 4,
                    columnStart: 15,
                    lineEnd: 6,
                    columnEnd: 6
                ),
            ]
        )

        // The region is the `if` body, so `a == b` inside it goes. The condition `a && b` sits on the
        // region's first line but before it starts, and runs whether or not the body does.
        let mutants = mappings
            .flatMap(\.mutationSchemata)
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
        XCTAssertEqual(Set(mutants), ["ChangeLogicalConnector@4", "NegateConditional@4"])
    }

    // Every node's coverage check asks for its start and end. A location converter made for each took a pass over the
    // whole file each time, so a long file with any uncovered region took over a minute in a debug build.
    func test_regionsWithoutCoverage_keepDiscoveryFastOnALongFile() throws {
        let functions = (0 ..< 300).map { index in
            "public func check\(index)(_ a: Int, _ b: Int) -> Bool {\n    return a == b && a > \(index)\n}\n"
        }
        let source = try sourceCode("import Foundation\n\n" + functions.joined(separator: "\n"))
        let started = Date()

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 3, columnStart: 50, lineEnd: 5, columnEnd: 2)]
        )

        let seconds = Date().timeIntervalSince(started)
        XCTAssertTrue(seconds < 5, "\(seconds) s")
        // The region is the first function's body, so its six mutants go, and every other function keeps its six:
        // `&&` gets one, `==` RelationalOperatorReplacement's two constants, and `>` that operator's swap and constant
        // and RelationalBoundary's.
        XCTAssertEqual(mappings.flatMap(\.mutationSchemata).count, 299 * 6)
    }

    func test_keepCoveredCodeAfterARegionWithoutCoverage() throws {
        let source = try sourceCode("""
        import Foundation

        public func foo(_ a: Bool, _ b: Bool) -> Bool {
            if a {
                return false
            }

            return a == b
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [
                // The `if` body: it ends on line 6, before `a == b` on line 8 starts.
                .make(
                    lineStart: 4,
                    columnStart: 10,
                    lineEnd: 6,
                    columnEnd: 6
                ),
            ]
        )

        let mutants = mappings
            .flatMap(\.mutationSchemata)
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
        XCTAssertEqual(Set(mutants), ["NegateConditional@4", "RelationalOperatorReplacement@8"])
    }

    /// Each mutant as `<operator>@<line>`, in discovery's order, but RelationalBoundary's. That operator mutates the
    /// ordering operators that RelationalOperatorReplacement mutates, at the same places and judged by the same code's
    /// coverage. So its mutants are checked to be at exactly the places of RelationalOperatorReplacement's mutants of
    /// `<`, `<=`, `>` and `>=`, and then left out, so that each test names RelationalOperatorReplacement's alone.
    /// NegateConditional's are left out too, as its condition is judged in `NegateConditionalOperatorTests`.
    func mutants(
        in mappings: [SchemataMutationMapping],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        let schemata = mappings.flatMap(\.mutationSchemata)
        let place = { (schema: MutationSchema) in "\(schema.filePath)@\(schema.position.utf8Offset)" }
        let orderings = schemata
            .filter { $0.mutationOperatorId == .ror && ["<", "<=", ">", ">="].contains($0.snapshot.before) }
            .map(place)
        let boundaries = schemata.filter { $0.mutationOperatorId == .relationalBoundary }.map(place)
        XCTAssertEqual(boundaries.sorted(), orderings.sorted(), "the boundary mutants' places", file: file, line: line)

        return schemata
            .filter { ![.relationalBoundary, .negateConditional].contains($0.mutationOperatorId) }
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
    }
}

private let sampleWithComplexDisableRules =
    """
        import Foundation

        // muter:disable
        func f() {
            doSomething(testableSideEffect: true)
        }

        // muter:enable
        func f() {
            doSomething(testableSideEffect: false)
        }

        // muter:disable
        struct IgnoreMe {

            func f() -> Bool {
                // muter:enable
                let b = a == 5
                // muter:disable
                let e = a != 1
                // muter:enable
                return a ? "true" : "false"
            }
        }
    """

private let sampleWithDisabledMutations =
    """
    import Foundation

    func f() {
        doSomething(testableSideEffect: true)
    }

    // muter:disable
    func f() {
        doSomething(testableSideEffect: false)
    }

    struct IgnoreMe {

        func f() {
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: false)
        }
    }
    """

private let sampleWithTopLevelDisable =
    """
    // muter:disable

    import Foundation

    func f() {
        doSomething(testableSideEffect: true)
    }

    func f() {
        doSomething(testableSideEffect: true)
        doSomething(testableSideEffect: false)
    }

    struct IgnoreMe {
        func f() {
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: false)
        }
    }

    """
