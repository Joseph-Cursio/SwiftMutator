@testable import muterCore
import SwiftParser
import XCTest

/// Pinning a failed build's compile errors on the mutants at fault, and writing their files again without them.
final class CompileRecoveryTests: MuterTestCase {
    /// Without ReplaceReturnValue, whose mutant of a function's whole value, as `other`'s `3` or `total`'s call of a
    /// builder, would change which switches these files have: its own shapes compile in GeneratedCodeShapesTests.
    override var operatorsToDiscoverWith: MutationOperatorList {
        super.operatorsToDiscoverWith.filter { $0 != .replaceReturnValue }
    }

    let path = "/project_mutated/Sources/Check.swift"
    let state = MutationTestState()
    let oneChain = """
    func check(_ value: Int) -> Bool {
        return value > 1
    }

    func other() -> Int { 3 }

    """
    let written = Locked<[(path: String, code: String)]>([])
    var writes: [(path: String, code: String)] { written.value }

    override func setUp() {
        super.setUp()
        current.writeFile = { [written] code, path in written.change { $0.append((path, code)) } }
    }

    // MARK: Where an error is

    func test_anErrorInABranch_isThatMutants() throws {
        let file = try file(oneChain)
        for id in file.ids {
            let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)
            assertBranch(of: id, at: place, in: file)
        }
    }

    // A chain's branches can share one line, so a line alone can't name a mutant.
    func test_twoMutantsOnOneLine_areToldApartByColumn() throws {
        let file = try file("func check(_ a: Int) -> Bool { a > 1 }\n")
        let places = try file.ids.map { place(of: try branchBody(of: $0, in: file.rewritten), in: file.rewritten) }

        XCTAssertEqual(Set(places.map(\.line)).count, 1)
        XCTAssertEqual(Set(places.map(\.column)).count, file.ids.count)
        for (id, place) in zip(file.ids, places) {
            assertBranch(of: id, at: place, in: file)
        }
    }

    func test_anErrorOnASwitchsIfOrInItsFinalElse_isNoOneMutants() throws {
        let file = try file(oneChain)
        let keyword = place(of: try XCTUnwrap(file.rewritten.range(of: "if __SwiftMutator")), in: file.rewritten)
        let finalElse = place(of: try XCTUnwrap(file.rewritten.range(of: "} else {")), in: file.rewritten)

        // A chain lists its mutants as its code does, which is the order of no other list.
        for (line, column) in [
            (keyword.line, keyword.column),
            (finalElse.line, finalElse.column + "} else { ".utf8.count + 8),
        ] {
            guard case let .wholeSwitch(chain) = locator(file).place(line: line, column: column) else {
                XCTFail(file.rewritten)
                return
            }
            XCTAssertEqual(Set(chain), Set(file.ids))
        }
    }

    func test_anErrorInCodeSwiftMutatorWrote_isTold() throws {
        let file = try file(oneChain)
        let id = try XCTUnwrap(file.ids.first)
        let condition = place(of: try XCTUnwrap(file.rewritten.range(of: "\"\(id)\"")), in: file.rewritten)
        let cache = place(of: try XCTUnwrap(file.rewritten.range(of: "static let environment")), in: file.rewritten)

        XCTAssertEqual(locator(file).place(line: condition.line, column: condition.column), .condition)
        XCTAssertEqual(locator(file).place(line: cache.line, column: cache.column), .environmentCache)
    }

    func test_anErrorOutsideAnySwitch_namesTheMutantsOfTheCodeAroundIt_ifAny() throws {
        let file = try file(oneChain)
        let enumStart = try XCTUnwrap(file.rewritten.range(of: "@usableFromInline internal enum")).lowerBound
        let otherBody = place(of: try XCTUnwrap(file.rewritten.range(of: "3 }")), in: file.rewritten)
        let closingBrace = place(
            of: try XCTUnwrap(
                file.rewritten.range(of: "\n}", options: .backwards, range: file.rewritten.startIndex ..< enumStart)
            ),
            in: file.rewritten
        )

        XCTAssertEqual(locator(file).place(line: otherBody.line, column: otherBody.column), .outside)
        XCTAssertEqual(locator(file).mutantsInEnclosingBody(line: otherBody.line, column: otherBody.column), [])
        XCTAssertEqual(locator(file).place(line: closingBrace.line + 1, column: 1), .outside)
        XCTAssertEqual(
            Set(locator(file).mutantsInEnclosingBody(line: closingBrace.line + 1, column: 1)),
            Set(file.ids)
        )
    }

    func test_aPlacePastTheFilesEnd_isInNoSwitch() throws {
        let file = try file(oneChain)
        XCTAssertEqual(locator(file).place(line: 9_999, column: 1), .outside)
    }

    // The compiler counts columns in UTF-8 bytes, and takes a CR LF for one line break.
    func test_multiByteTextAndCRLFs_keepAnErrorInItsBranch() throws {
        let code = "func check(_ a: Int) -> Bool {\n    let _ = \"日本語🙂\"; return a > 1\n}\n"
            .replacingOccurrences(of: "\n", with: "\r\n")
        let file = try file(code)
        let id = try XCTUnwrap(file.ids.last)
        let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)

        assertBranch(of: id, at: place, in: file)
    }

    // A nested switch is in its outer chain's final `else`, and the innermost mutant is the one to blame.
    func test_anErrorInANestedSwitchsBranch_isTheInnermostMutants() throws {
        let file = try file("""
        func check(_ flag: Bool, _ a: Int) -> Int {
            return flag ? [1].map { $0 > a ? 1 : 2 }[0] : 3
        }

        """)
        let inner = try XCTUnwrap(file.ids.first { id in
            let lines = file.rewritten.components(separatedBy: "\n")
            guard let line = lines.first(where: { $0.contains("\"\(id)\"") }) else { return false }
            return line.contains("$0") || !line.contains("flag")
        })
        let place = place(of: try branchBody(of: inner, in: file.rewritten), in: file.rewritten)

        guard case let .branch(id, _) = locator(file).place(line: place.line, column: place.column) else {
            XCTFail("\(file.rewritten)")
            return
        }
        XCTAssertEqual(id, inner)
    }

    // MARK: Taking mutants out

    // A command that builds something else first, a quoted line, and a test's own failure.
    func test_testsStarted_isOnlyALastBuildsCompletion() {
        XCTAssertTrue(CompileRecovery.testsStarted(in: "Building for debugging...\nBuild complete! (2.1s)\nerror: x\n"))
        XCTAssertTrue(CompileRecovery.testsStarted(in: "\u{1B}[1mBuild complete!\u{1B}[0m (2.1s)\n"))
        XCTAssertFalse(
            CompileRecovery.testsStarted(
                in: "Build complete! (2.1s)\nBuilding for debugging...\nA.swift:1:1: error: x\n"
            )
        )
        XCTAssertFalse(CompileRecovery.testsStarted(in: "24 | public let line = \"Build complete!\"\nerror: x\n"))
        XCTAssertFalse(CompileRecovery.testsStarted(in: "Building for debugging...\nerror: x\n"))
    }

    func test_anEarlierBuildsCompletion_leavesRecoveryOn() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let line = try error(atBranchOf: file.ids[0], in: file, saying: "nope")

        let count = try await recovery.takeOutMutants(
            failing: "Build complete! (1s)\nBuilding for debugging...\n" + line,
            keptAs: "log",
            testsMayHaveRun: true
        )

        XCTAssertEqual(count, 1)
    }

    // A build that runs `swiftc` on paths relative to the copy prints them so.
    func test_aRelativePathInALog_isOfTheCopy() async throws {
        let file = try file(oneChain)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        var recovery = try recovery(of: file)
        let place = place(of: try branchBody(of: file.ids[0], in: file.rewritten), in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "Sources/Check.swift:\(place.line):\(place.column): error: nope",
            keptAs: "log"
        )

        XCTAssertEqual(count, 1)
    }

    func test_aFileThatCantBeWritten_stopsTheRun() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        current.writeFile = { _, _ in throw TestingError.stub }

        try await assertThrowsMuterError(
            await recovery.takeOutMutants(
                failing: error(atBranchOf: file.ids[0], in: file, saying: "nope"),
                keptAs: "log"
            ),
            .literal(reason: TestingError.stub.localizedDescription)
        )
    }

    // A test plan's copy may have been fixed by hand, and its schemata can't be rewritten.
    func test_aTestPlansRun_hasNoRecovery() throws {
        let file = try file(oneChain)
        state.mutationMapping = [file.mapping]
        state.preparedSources = [:]
        XCTAssertNil(CompileRecovery(of: state))

        state.preparedSources = [path: file.prepared]
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/plan.json"))
        XCTAssertNil(CompileRecovery(of: state))
    }

    // MARK: What's said

    func test_aLeftOutMutantsLog_saysWhyInTheCompilersWords() {
        let error = CompilerError(filePath: "/f.swift", line: 9, column: 3, message: "no such operator")

        XCTAssertEqual(
            LeftOutMutant(blame: .itself, errors: [error], buildLog: "failed build 1.log").log,
            """
            This mutant was taken out of the build, as it doesn't compile. Its tests never ran.

              no such operator

            The build's log is failed build 1.log.

            """
        )
        XCTAssertTrue(
            LeftOutMutant(blame: .itsFile, errors: [error], buildLog: "log").log
                .contains("with the rest of its file's mutants")
        )
    }

    func test_aLeftOutMutantsWarningLine_isNoIssueToXcode() {
        let key = MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 9, column: 3, occurrence: 0)
        let error = CompilerError(filePath: "/f.swift", line: 12, column: 3, message: "no such operator")
        let mutant = MutantsLeftOut.Mutant(
            key: key,
            change: "changed < to >",
            mutant: LeftOutMutant(blame: .itsFile, errors: [error], buildLog: "log")
        )

        XCTAssertEqual(
            mutant.line,
            "\(key) (changed < to >): no such operator [with the rest of its file]"
        )
        XCTAssertFalse(mutant.line.contains("error:"))
        XCTAssertFalse(mutant.line.contains("warning:"))
    }
}
