@testable import muterCore
import XCTest

extension CompileRecoveryTests {
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
}
