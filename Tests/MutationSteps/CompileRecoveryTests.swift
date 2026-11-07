@testable import muterCore
import SwiftParser
import XCTest

/// Pinning a failed build's compile errors on the mutants at fault, and writing their files again without them.
final class CompileRecoveryTests: MuterTestCase {
    private let path = "/project_mutated/Sources/Check.swift"
    private let state = MutationTestState()
    private let oneChain = """
    func check(_ value: Int) -> Bool {
        return value > 1
    }

    func other() -> Int { 3 }

    """
    private let written = Locked<[(path: String, code: String)]>([])
    private var writes: [(path: String, code: String)] { written.value }

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
                return XCTFail(file.rewritten)
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
        XCTAssertEqual(locator(file).place(line: 9999, column: 1), .outside)
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
            return XCTFail("\(file.rewritten)")
        }
        XCTAssertEqual(id, inner)
    }

    // MARK: Taking mutants out

    func test_anErrorInABranch_takesOutThatMutantAlone_andRewritesTheFileWithoutIt() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let id = try XCTUnwrap(file.ids.first)

        let count = try await recovery.takeOutMutants(
            failing: error(atBranchOf: id, in: file, saying: "no such operator"),
            keptAs: "failed build 1.log"
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(Array(recovery.leftOut.keys), [id])
        XCTAssertEqual(recovery.leftOut[id]?.blame, .itself)
        XCTAssertEqual(recovery.leftOut[id]?.buildLog, "failed build 1.log")
        XCTAssertEqual(recovery.leftOut[id]?.errors.map(\.message), ["no such operator"])
        XCTAssertEqual(writes.map(\.path), [path])
        var kept = file.mapping
        kept.keepOnly { $0.id != id }
        let expected = await ApplySchemata.rewritten(file.prepared, with: kept)
        XCTAssertEqual(writes.last?.code, expected)
        XCTAssertFalse(expected.contains("\"\(id)\""))
        for other in file.ids.dropFirst() {
            XCTAssertTrue(expected.contains("\"\(other)\""), expected)
        }
    }

    // SwiftPM's log colours its errors, and it hid them all from the parser.
    func test_aColouredErrorLine_isRead() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let id = try XCTUnwrap(file.ids.first)
        let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)
        let log = "\(path):\(place.line):\(place.column): \u{1B}[1;31merror: \u{1B}[1;39mno such operator\u{1B}[0;0m\n"

        let count = try await recovery.takeOutMutants(failing: log, keptAs: "log")

        XCTAssertEqual(count, 1)
        XCTAssertEqual(recovery.leftOut[id]?.errors.map(\.message), ["no such operator"])
    }

    // xcodebuild prints each error once per architecture.
    func test_anErrorPrintedTwice_isCountedOnce() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let id = try XCTUnwrap(file.ids.first)
        let line = try error(atBranchOf: id, in: file, saying: "no such operator")

        let count = try await recovery.takeOutMutants(failing: line + "\n" + line, keptAs: "log")

        XCTAssertEqual(count, 1)
        XCTAssertEqual(recovery.leftOut[id]?.errors.count, 1)
    }

    // A file's path as the build spells it isn't always as SwiftMutator does: xcodebuild's has /private dropped.
    func test_aFileIsFoundByItsCanonicalPath() async throws {
        let directory = try makeTemporaryDirectory()
        let filePath = "\(directory)/Check.swift"
        try Data().write(to: URL(fileURLWithPath: filePath))
        let linkDirectory = "\(directory)_link"
        try FileManager.default.createSymbolicLink(atPath: linkDirectory, withDestinationPath: directory)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: linkDirectory) }
        let file = try file(oneChain, at: filePath)
        var recovery = try recovery(of: file)
        let id = try XCTUnwrap(file.ids.first)
        let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "\(linkDirectory)/Check.swift:\(place.line):\(place.column): error: no such operator",
            keptAs: "log"
        )

        XCTAssertEqual(count, 1)
    }

    func test_anErrorInAnotherFile_stopsWithNothingTakenOut() async throws {
        var recovery = try recovery(of: try file(oneChain))

        let count = try await recovery.takeOutMutants(
            failing: "/project_mutated/Sources/Other.swift:3:1: error: oops",
            keptAs: "log"
        )

        XCTAssertNil(count)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(recovery.leftOut.isEmpty)
    }

    // With a file of the same name elsewhere, its error isn't this file's.
    func test_anErrorInASameNamedFileOfAnotherTarget_stopsWithNothingTakenOut() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let place = place(of: try branchBody(of: file.ids[0], in: file.rewritten), in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "/project_mutated/Sources/Elsewhere/Check.swift:\(place.line):\(place.column): error: oops",
            keptAs: "log"
        )

        XCTAssertNil(count)
    }

    func test_aFailedTest_stopsWithNothingTakenOut() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let line = try error(atBranchOf: file.ids[0], in: file, saying: "printed by a failing test")

        let count = try await recovery.takeOutMutants(
            failing: "Build complete! (2.1s)\n" + line,
            keptAs: "log",
            testsMayHaveRun: true
        )

        XCTAssertNil(count)
        XCTAssertTrue(writes.isEmpty)
    }

    func test_aLogWithNoErrors_stopsWithNothingTakenOut() async throws {
        var recovery = try recovery(of: try file(oneChain))

        let count = try await recovery.takeOutMutants(failing: "error: fatalError\n", keptAs: "log")

        XCTAssertNil(count)
    }

    // Taking the mutants out would make the file compile, as the cache goes with them: a bug in the rewriting would
    // look like mutants that don't compile, and could lose every one of them.
    func test_anErrorInCodeSwiftMutatorWrote_stopsWithNothingTakenOut_evenWithAnotherToBlame() async throws {
        let file = try file(oneChain)
        for marker in ["\"\(file.ids[0])\"", "static let environment"] {
            var recovery = try recovery(of: file)
            let inIt = place(of: try XCTUnwrap(file.rewritten.range(of: marker)), in: file.rewritten)
            let inBranch = try error(atBranchOf: file.ids[0], in: file, saying: "a mutant's")

            let count = try await recovery.takeOutMutants(
                failing: "\(path):\(inIt.line):\(inIt.column): error: ours\n\(inBranch)",
                keptAs: "log"
            )

            XCTAssertNil(count, marker)
            XCTAssertTrue(writes.isEmpty, marker)
            XCTAssertTrue(recovery.leftOut.isEmpty, marker)
        }
    }

    func test_anErrorOnASwitch_takesOutItsChain() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let keyword = place(of: try XCTUnwrap(file.rewritten.range(of: "if __SwiftMutator")), in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "\(path):\(keyword.line):\(keyword.column): error: type mismatch",
            keptAs: "log"
        )

        XCTAssertEqual(count, file.ids.count)
        XCTAssertEqual(Set(recovery.leftOut.keys), Set(file.ids))
        XCTAssertEqual(recovery.leftOut[file.ids[0]]?.blame, .itsSwitch)
    }

    // The compiler reports this on the first branch of a differing type, whichever mutants are at fault.
    func test_mismatchingBranchTypes_takeOutTheChain() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)

        let count = try await recovery.takeOutMutants(
            failing: error(atBranchOf: file.ids[0], in: file, saying: "branches have mismatching types 'A' and 'B'"),
            keptAs: "log"
        )

        XCTAssertEqual(count, file.ids.count)
    }

    // A missing `return` is reported on the function's closing brace.
    func test_anErrorOutsideASwitch_takesOutTheMutantsAroundIt_andNoOthers() async throws {
        let two = """
        func check(_ value: Int) -> Bool {
            return value > 1
        }

        func other(_ value: Int) -> Bool {
            return value < 1
        }

        """
        let file = try file(two)
        var recovery = try recovery(of: file)
        let firstOther = try XCTUnwrap(file.rewritten.range(of: "func other"))
        let braces = place(of: firstOther, in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "\(path):\(braces.line - 2):1: error: missing return",
            keptAs: "log"
        )

        let check = file.mapping.mutationSchemata.filter { $0.position.line == 2 }.map(\.id)
        XCTAssertEqual(count, check.count)
        XCTAssertEqual(Set(recovery.leftOut.keys), Set(check))
        XCTAssertEqual(recovery.leftOut[check[0]]?.blame, .itsEnclosingCode)
    }

    // An error in code around no mutant, such as a type's member, can't be pinned closer than its file.
    func test_anErrorInNoCodeAroundAMutant_takesOutTheFilesMutants_thenStopsIfItStays() async throws {
        let file = try file(oneChain)
        var recovery = try recovery(of: file)
        let body = place(of: try XCTUnwrap(file.rewritten.range(of: "3 }")), in: file.rewritten)
        let log = "\(path):\(body.line):\(body.column): error: the project's own"

        let first = try await recovery.takeOutMutants(failing: log, keptAs: "failed build 1.log")
        XCTAssertEqual(first, file.ids.count)
        XCTAssertEqual(recovery.leftOut[file.ids[0]]?.blame, .itsFile)
        XCTAssertFalse(writes.last?.code.contains("__SwiftMutator") ?? true)
        XCTAssertEqual(writes.last?.code, file.prepared)

        let second = try await recovery.takeOutMutants(failing: log, keptAs: "failed build 2.log")
        XCTAssertNil(second)
        XCTAssertEqual(writes.count, 1)
    }

    // Each build costs as much as a project's incremental build, and can report one error of many.
    func test_afterSomeFailedBuilds_errorsAreBlamedMoreWidely() async throws {
        let code = (1 ... 12)
            .map { "func f\($0)(_ a: Int) -> Bool {\n    return a > \($0)\n}\n" }
            .joined(separator: "\n")
        let file = try file(code)
        let perFunction = file.mapping.mutationSchemata.filter { $0.position.line == 2 }.count
        var recovery = try recovery(of: file)
        var counts: [Int] = []
        var blames: [LeftOutMutant.Blame] = []
        var remaining = file.mapping
        for build in 1 ... (CompileRecovery.buildsPerWidening * 2 + 1) {
            let line = (build - 1) * 4 + 2
            let id = try XCTUnwrap(remaining.mutationSchemata.first { $0.position.line == line }?.id)
            let rewritten = await ApplySchemata.rewritten(file.prepared, with: remaining)
            let place = place(of: try branchBody(of: id, in: rewritten), in: rewritten)
            let count = try await recovery.takeOutMutants(
                failing: "\(path):\(place.line):\(place.column): error: nope",
                keptAs: "log"
            )
            counts.append(try XCTUnwrap(count))
            blames.append(try XCTUnwrap(recovery.leftOut[id]).blame)
            let leftOut = recovery.leftOut
            remaining.keepOnly { leftOut[$0.id] == nil }
            if remaining.isEmpty { break }
        }

        let widening = CompileRecovery.buildsPerWidening
        XCTAssertEqual(Array(blames.prefix(widening)), Array(repeating: .itself, count: widening))
        XCTAssertEqual(Array(blames[widening ..< widening * 2]), Array(repeating: .itsEnclosingCode, count: widening))
        XCTAssertEqual(blames[widening * 2], .itsFile)
        XCTAssertEqual(Array(counts.prefix(widening)), Array(repeating: 1, count: widening))
        XCTAssertEqual(Array(counts[widening ..< widening * 2]), Array(repeating: perFunction, count: widening))
    }

    // With mutants left, and an error it could blame on them.
    func test_afterTheMostBuilds_itStops() async throws {
        let files = try (0 ... CompileRecovery.maximumBuilds).map {
            try file(oneChain, at: "/project_mutated/Sources/File\($0).swift")
        }
        state.mutationMapping = files.map(\.mapping)
        state.preparedSources = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.prepared) })
        var recovery = try XCTUnwrap(CompileRecovery(of: state))
        for file in files.dropLast() {
            let count = try await recovery.takeOutMutants(
                failing: error(atBranchOf: file.ids[0], in: file, saying: "nope"),
                keptAs: "log"
            )
            XCTAssertNotNil(count)
        }
        XCTAssertTrue(recovery.stopsAtTheMostBuilds)
        let writtenBefore = writes.count

        let last = try XCTUnwrap(files.last)
        let count = try await recovery.takeOutMutants(
            failing: error(atBranchOf: last.ids[0], in: last, saying: "nope"),
            keptAs: "log"
        )

        XCTAssertNil(count)
        XCTAssertEqual(writes.count, writtenBefore)
    }

    // An import is the project's, however its next build goes: a build order can fail it once.
    func test_anErrorInAnImport_stopsWithNothingTakenOut_atEveryWidening() throws {
        let file = try file("import Dep\n\n" + oneChain)
        let place = place(of: try XCTUnwrap(file.rewritten.range(of: "Dep")), in: file.rewritten)
        let error = CompilerError(
            filePath: path,
            line: place.line,
            column: place.column,
            message: "no such module 'Dep'"
        )

        XCTAssertEqual(locator(file).place(line: place.line, column: place.column), .importDeclaration)
        for builds in [1, CompileRecovery.buildsPerWidening + 1, CompileRecovery.buildsPerWidening * 2 + 1] {
            XCTAssertNil(locator(file).mutantsAt(error, everyMutant: file.ids, afterFailedBuilds: builds))
        }
    }

    // A missing `return` comes of a statement that is gone: the rest may be innocent, and go only if it stays.
    // RemoveSideEffects keeps a call that ends a function that returns a value, but not one that ends a `repeat` body
    // there.
    func test_anErrorAroundAMutantThatRemovesAStatement_takesThatOneOutFirst() async throws {
        let code = """
        func die() -> Never { fatalError() }
        func check(_ value: Int) -> Bool {
            if value > 1 { return true }
            repeat {
                die()
            } while value < 0
        }

        """
        let file = try file(code)
        let removal = try XCTUnwrap(
            file.mapping.mutationSchemata.first { $0.mutationOperatorId == .removeSideEffects && $0.position.line == 5 }
        )
        var recovery = try recovery(of: file)
        let enumStart = try XCTUnwrap(file.rewritten.range(of: "@usableFromInline internal enum")).lowerBound
        let closingBrace = place(
            of: try XCTUnwrap(
                file.rewritten.range(of: "\n}", options: .backwards, range: file.rewritten.startIndex ..< enumStart)
            ),
            in: file.rewritten
        )
        let log = "\(path):\(closingBrace.line + 1):1: error: missing return in global function"

        let count = try await recovery.takeOutMutants(failing: log, keptAs: "log")

        XCTAssertEqual(count, 1)
        XCTAssertEqual(Array(recovery.leftOut.keys), [removal.id])
        XCTAssertEqual(recovery.leftOut[removal.id]?.blame, .itself)
    }

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

private extension CompileRecoveryTests {
    struct File {
        let mapping: SchemataMutationMapping
        let prepared: String
        let rewritten: String
        let path: String
        var ids: [String] { mapping.mutationSchemata.map(\.id) }
    }

    func file(_ code: String, at filePath: String? = nil) throws -> File {
        let filePath = filePath ?? path
        let source = SourceCodeInfo(path: filePath, code: Parser.parse(source: code))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        XCTAssertGreaterThan(mapping.mutationSchemata.count, 1)
        return File(
            mapping: mapping,
            prepared: code,
            rewritten: MuterRewriter(mapping).visit(source.code).description,
            path: filePath
        )
    }

    func assertBranch(
        of id: String,
        at place: (line: Int, column: Int),
        in file: File,
        fileName: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .branch(found, chain) = locator(file).place(line: place.line, column: place.column) else {
            return XCTFail(file.rewritten, file: fileName, line: line)
        }
        XCTAssertEqual(found, id, file: fileName, line: line)
        XCTAssertEqual(Set(chain), Set(file.ids), file: fileName, line: line)
    }

    func locator(_ file: File) -> MutantLocator {
        MutantLocator(rewritten: file.rewritten, filePath: file.path)
    }

    func recovery(of file: File) throws -> CompileRecovery {
        state.mutationMapping = [file.mapping]
        state.preparedSources = [file.path: file.prepared]
        return try XCTUnwrap(CompileRecovery(of: state))
    }

    /// The range of the first token of `id`'s branch.
    func branchBody(of id: String, in code: String) throws -> Range<String.Index> {
        let id = try XCTUnwrap(code.range(of: "\"\(id)\"] != nil"), code)
        let brace = try XCTUnwrap(code[id.upperBound...].firstIndex(of: "{"), code)
        let condition = brace ..< code.index(after: brace)
        let start = try XCTUnwrap(code[condition.upperBound...].firstIndex { !$0.isWhitespace && !$0.isNewline }, code)
        return start ..< code.index(after: start)
    }

    /// The line and column of `range`'s start, as the compiler prints them: columns in UTF-8 bytes.
    func place(of range: Range<String.Index>, in code: String) -> (line: Int, column: Int) {
        let before = code[..<range.lowerBound].utf8
        let lastLineBreak = before.lastIndex(of: UInt8(ascii: "\n"))
        let lineStart = lastLineBreak.map { before.index(after: $0) } ?? before.startIndex
        return (
            before.count(where: { $0 == UInt8(ascii: "\n") }) + 1,
            before.distance(from: lineStart, to: before.endIndex) + 1
        )
    }

    func error(atBranchOf id: String, in file: File, saying message: String) throws -> String {
        let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)
        return "\(file.path):\(place.line):\(place.column): error: \(message)"
    }
}
