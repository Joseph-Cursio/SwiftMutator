@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    func test_resultsFileCreated_andKept_nameTheFile() {
        sut.resultsFileCreated(atPath: "/logs/results.jsonl")
        sut.resultsFileKept(atPath: "/logs/results.jsonl")

        XCTAssertEqual(printer.linesPassed, [
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)",
            "💾 Each mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    // The progress bar counts the mutants left to test, not every one discovery found. Each reason a mutant is tested
    // again is counted, in the plan's order, and only when it has any.
    func test_resumePlanned_saysWhatIsReusedAndRetested_andSetsTheProgressTotal() throws {
        try sut.mutationsDiscoveryFinished(mutations: Array(repeating: makeSchemataMapping(), count: 4))
        let printedBefore = printer.linesPassed.count

        sut.resumePlanned(.make(reused: 1_103, toTest: 1_394, retestedBecause: [.buildError: 5, .notRecorded: 1_389]))

        XCTAssertEqual(sut.numberOfMutationPoints, 1_394)
        sut.resumePlanned(
            .make(
                reused: 1,
                toTest: 7,
                retestedBecause: [.repeated: 2, .mutationChanged: 1, .fileChanged: 3, .buildError: 1, .notRecorded: 0]
            )
        )
        sut.resumePlanned(.make(reused: 0, toTest: 1, retestedBecause: [.fileChanged: 1]))

        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1103 results still hold, "
                + "so 1394 mutants are left to test (1389 never tested, 5 build errors).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1 result still holds, so 7 mutants are left to test "
                + "(1 build error, 3 in changed files, 1 changed mutation, 2 repeated in their file).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 0 results still hold, "
                + "so 1 mutant is left to test (1 in a changed file).",
        ])
        XCTAssertEqual(sut.numberOfMutationPoints, 1)
    }

    func test_resumePlanned_withNothingLeft_saysSo() {
        sut.resumePlanned(.make(reused: 2_497, toTest: 0, retestedBecause: [:]))
        sut.resumePlanned(.make(reused: 1, toTest: 0, retestedBecause: [:]))

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): all 2497 results still hold, "
                + "so nothing is left to test.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): its only result still holds, "
                + "so nothing is left to test.",
        ])
        XCTAssertEqual(sut.numberOfMutationPoints, 0)
    }

    // A change no result depends on is only said. What --force-resume and --resume-ignoring let through is a warning:
    // the results are reused on the user's word.
    func test_resumePlanned_namesForcedWaivedAndNotices() {
        sut.resumePlanned(
            .make(
                forced: ["swiftMutator.executableSHA256", "toolchain.testCommandVersion"],
                waived: ["README.md", "notes.txt"],
                notices: ["mutationTestWorkers was 4 and is 2 now, which no result depends on."]
            )
        )
        sut.resumePlanned(
            .make(
                forced: ["toolchain.environment"],
                waived: (1...12).map { "Docs/rules/rule\($0).md" }
            )
        )

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.",
            "⚠️ Results are reused although SwiftMutator and the toolchain changed (--force-resume).",
            "⚠️ Results are reused although 2 project files changed (--resume-ignoring): README.md, notes.txt",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "⚠️ Results are reused although the toolchain's environment changed (--force-resume).",
            "⚠️ Results are reused although 12 project files changed (--resume-ignoring): "
                + (1...10).map { "Docs/rules/rule\($0).md" }.joined(separator: ", ") + ", and 2 more",
        ])
    }

    // A resume of a test plan's run compares the plan's copy, not the project: what --resume-ignoring let through are
    // the copy's files, named as the refusal names them.
    func test_resumePlanned_ofATestPlansRun_namesTheWaivedFilesAsTheCopys() {
        sut.resumePlanned(.make(waived: ["Sources/Sum.swift"], testPlanCopy: "/work/Foo_mutated"))
        sut.resumePlanned(.make(waived: ["Sources/Max.swift", "Sources/Sum.swift"], testPlanCopy: "/work/Foo_mutated"))

        XCTAssertEqual(Array(printer.linesPassed.filter { $0.hasPrefix("⚠️") }), [
            "⚠️ Results are reused although 1 file of the test plan's copy, /work/Foo_mutated, changed "
                + "(--resume-ignoring): Sources/Sum.swift",
            "⚠️ Results are reused although 2 files of the test plan's copy, /work/Foo_mutated, changed "
                + "(--resume-ignoring): Sources/Max.swift, Sources/Sum.swift",
        ])
    }

    // A reuse says what a resume does, with its own flags, and why it tests what it tests again: a changed file other
    // than a test, with the globs that would let it through, or changed test files.
    func test_reusePlanned_namesItsFlags_andWhatMadeItTestAgain() {
        sut.resumePlanned(
            .make(
                reused: 0,
                toTest: 3,
                retestedBecause: [.otherFileChanged: 2, .timedOut: 1],
                forced: ["toolchain.environment"],
                waived: ["notes.txt"],
                isReuse: true,
                otherFilesChanged: [
                    .init(path: "Package.resolved", kind: .changed),
                    .init(path: "Docs/[a].md", kind: .added),
                ]
            )
        )
        sut.resumePlanned(
            .make(reused: 5, toTest: 2, retestedBecause: [.testsChanged: 2], isReuse: true, testFilesChanged: 1)
        )

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Reusing the results in \("/logs/results.jsonl".bold): 0 results still hold, "
                + "so 3 mutants are left to test (1 timeout, 2 as other project files changed).",
            "⚠️ 2 project files other than tests changed since that run's results were tested, so they are tested "
                + "again: Package.resolved (changed), Docs/[a].md (added). If they can't change any test's result: "
                + "--reuse-ignoring 'Package.resolved' --reuse-ignoring 'Docs/\\[a].md'",
            "⚠️ Results are reused although the toolchain's environment changed (--force-reuse).",
            "⚠️ Results are reused although 1 project file changed (--reuse-ignoring): notes.txt",
            "♻️ Reusing the results in \("/logs/results.jsonl".bold): 5 results still hold, "
                + "so 2 mutants are left to test (2 as test files changed).",
            "ℹ️ 1 test file changed, so every survivor is tested again, and every kill that no unchanged test still "
                + "holds.",
        ])
        XCTAssertEqual(sut.numberOfMutationPoints, 2)
    }
}
