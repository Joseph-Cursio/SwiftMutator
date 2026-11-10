@testable import muterCore
import SwiftParser
import XCTest

extension CompileRecoveryTests {
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

    // A result builder without `buildEither` can't take the switch's `if` (#206). The closure's one expression is
    // switched in a closure called on the spot instead, and no mutant is taken out.
    func test_aSwitchABuilderCantTake_goesInAClosureCalledOnTheSpot_andItsMutantsStay() async throws {
        let file = try file("func total(_ value: Int) -> Int { sum { value > 1 ? 10 : 20 } }\n")
        var recovery = try recovery(of: file)
        let keyword = place(of: try XCTUnwrap(file.rewritten.range(of: "if __SwiftMutator")), in: file.rewritten)

        let count = try await recovery.takeOutMutants(
            failing: "\(path):\(keyword.line):\(keyword.column): error: \(builderError)",
            keptAs: "log"
        )

        XCTAssertEqual(count, 0)
        XCTAssertEqual(recovery.switchedInAClosure, file.ids.count)
        XCTAssertTrue(recovery.leftOut.isEmpty)
        let code = try XCTUnwrap(writes.last?.code)
        XCTAssertTrue(code.contains("sum { { if __SwiftMutator"), code)
        XCTAssertTrue(code.contains("} else {return value > 1 ? 10 : 20} }() }"), code)
        XCTAssertTrue(CheckMutantSwitches.mutantsWithoutASwitch(in: code, of: file.mapping).isEmpty)

        // Its switch now holds `return`s, so a builder error on it again takes its mutants out, as any other error.
        let again = place(of: try XCTUnwrap(code.range(of: "if __SwiftMutator")), in: code)
        let next = try await recovery.takeOutMutants(
            failing: "\(path):\(again.line):\(again.column): error: \(builderError)",
            keptAs: "log"
        )
        XCTAssertEqual(next, file.ids.count)
        XCTAssertEqual(recovery.switchedInAClosure, 0)
    }

    // In a closure of its own, `$0` would be that closure's, and a closure of more than one expression would give the
    // builder one part, not several. Their mutants are taken out, as before.
    func test_aSwitchABuilderCantTake_inAClosureThatCantHoldIt_takesOutItsChain() async throws {
        for code in [
            "func total(_ values: [Int]) -> Int { sum(values) { $0 > 1 ? 10 : 20 } }\n",
            "func total(_ value: Int) -> Int { sum { 1; value > 1 ? 10 : 20 } }\n",
        ] {
            let file = try file(code)
            var recovery = try recovery(of: file)
            let keyword = place(of: try XCTUnwrap(file.rewritten.range(of: "if __SwiftMutator")), in: file.rewritten)

            let count = try await recovery.takeOutMutants(
                failing: "\(path):\(keyword.line):\(keyword.column): error: \(builderError)",
                keptAs: "log"
            )

            XCTAssertEqual(count, file.ids.count, code)
            XCTAssertEqual(recovery.switchedInAClosure, 0, code)
            XCTAssertEqual(recovery.leftOut[file.ids[0]]?.blame, .itsSwitch, code)
        }
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
}
