@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    // The block a run of one mutant ends with: what it changes, its tests' log, its verdict, the copy it leaves, and
    // the command that runs its tests there with it on, by its file for `swift test`. Every path is quoted for a
    // shell.
    func test_oneMutantTested_printsTheChange_theLog_theVerdict_andHowToSwitchItOn_forSwiftTest() {
        sut.oneMutantTested(.make(), reports: [])

        XCTAssertEqual(printer.linesPassed, [
            "🏁 SwiftMutator finished running!",
            "🔬 Sources/Foo/Bar.swift:12:9 SwapTernary (swapped ternary operator)",
            "Switch: Bar_1a2b_SwapTernary_12_9_412",
            "Change:",
            "  -12:     return a ? b : c",
            "  +12:     return a ? c : b",
            "Tests (log: /logs/Oct 4/SwapTernary @ Bar.swift-12-9 1a2b.log):",
            "  ✘ Test picksB() recorded an issue at BarTests.swift:3:5",
            "",
            "  ✘ Test run with 1 test failed.",
            "Verdict: killed by picksB() (1 failed test), in 4.2 s",
            "Mutated project kept, with the mutant switched off: /work/Foo's copy/Foo_mutant",
            "To run its tests with it on:",
            #"  printf '%s\n' 'Bar_1a2b_SwapTernary_12_9_412' > '/work/Foo'\''s copy/Foo_mutant.active-mutant' && "#
                + #"cd '/work/Foo'\''s copy/Foo_mutant' && IS_MUTER_RUNNING=YES "#
                + #"SWIFTMUTATOR_ACTIVE_MUTANT_FILE='/work/Foo'\''s copy/Foo_mutant.active-mutant' "#
                + "/usr/bin/swift test 'Flag with space'",
        ])
    }

    // Another test command is given the mutant's own variable, by `env`, as its ID needn't be a shell variable's name.
    // An xcodebuild run sets it in `muter.xctestrun`, so only the variables are named.
    func test_oneMutantTested_switchesItOnByItsVariable_forOtherTestCommands() {
        sut.oneMutantTested(
            .make(buildSystem: .unknown, testCommand: ["/bin/sh", "-c", "make test"]),
            reports: []
        )
        sut.oneMutantTested(
            .make(buildSystem: .xcodebuild, testCommand: ["/usr/bin/xcodebuild", "test"]),
            reports: []
        )

        XCTAssertEqual(printer.linesPassed.filter { $0.hasPrefix("To run") || $0.hasPrefix("  cd ") }, [
            "To run its tests with it on:",
            #"  cd '/work/Foo'\''s copy/Foo_mutant' && env IS_MUTER_RUNNING=YES 'Bar_1a2b_SwapTernary_12_9_412=YES' "#
                + "/bin/sh -c 'make test'",
            "To run its tests with it on, set Bar_1a2b_SwapTernary_12_9_412=YES and IS_MUTER_RUNNING=YES in their "
                + "environment, and SIMCTL_CHILD_Bar_1a2b_SwapTernary_12_9_412=YES for a simulator.",
        ])
    }

    // A long log is printed from its end, where the failures and the summary are; the log folder keeps it whole.
    func test_oneMutantTested_printsTheLastLinesOfALongLog() {
        let log = (1 ... 401).map { "line \($0)" }.joined(separator: "\n") + "\n"

        sut.oneMutantTested(.make(testLog: log), reports: [])
        sut.oneMutantTested(.make(testLog: log, logPath: nil), reports: [])
        sut.oneMutantTested(.make(testLog: ""), reports: [])

        let lines = printer.linesPassed
        let first = lines.firstIndex(of: "  … 201 earlier lines are in the log")
        XCTAssertEqual(first.map { lines[$0 + 1] }, "  line 202")
        XCTAssertEqual(first.map { lines[$0 + 200] }, "  line 401")
        XCTAssertEqual(first.map { lines[$0 + 201] }, "Verdict: killed by picksB() (1 failed test), in 4.2 s")
        XCTAssertTrue(lines.contains("Tests:"), "\(lines)")
        XCTAssertTrue(lines.contains("  … 201 earlier lines are left out"), "\(lines)")
        XCTAssertTrue(lines.contains("  (the tests printed nothing)"), "\(lines)")
    }

    func test_oneMutantTested_givesEachVerdict() {
        let killing = MutationTestOutcome.KillingTests(
            tests: ["a()", "b()", "c()"].map { FailedTestLine.FailedTest(name: $0, location: nil) },
            count: 5,
            isComplete: true
        )

        XCTAssertEqual(
            [
                OneMutantRun.make(killingTests: killing),
                .make(outcome: .failed, killingTests: nil),
                .make(outcome: .runtimeError, killingTests: nil),
                .make(outcome: .passed, killingTests: nil),
                .make(outcome: .timeout, killingTests: nil),
                .make(outcome: .buildError, killingTests: nil),
            ].map(Logger.verdict(of:)),
            [
                "killed by a(), b(), c() and 2 more (5 failed tests), in 4.2 s",
                "killed: the tests failed, in 4.2 s",
                "killed: the tests crashed, in 4.2 s",
                "survived, in 4.2 s",
                "timed out after 30 s",
                "build error, in 4.2 s",
            ]
        )
    }

    // A report asked for with -o is still written, and said, after the block.
    func test_oneMutantTested_saysWhereARequestedReportWent() {
        sut.oneMutantTested(.make(), reports: [("/out/report.txt", true)])
        sut.oneMutantTested(.make(), reports: [("/out/report.txt", false)])

        XCTAssertEqual(printer.linesPassed.filter { $0.hasPrefix("📝") || $0.hasPrefix("⚠️") }, [
            "📝 Report generated: \("/out/report.txt".bold)",
            "⚠️ Could not save the report to /out/report.txt",
        ])
    }

    // Last, after where the report went or the report itself, whether or not it was saved: the line a run ends on.
    func test_mutationTestingFinished_withASuspectWarning_printsItLast() {
        let warning = "1 test may fail whatever the mutant: it failed for mutants in at least 15% of the 10 files "
            + "with a killed mutant (timing() in 10). Without its failures, the mutation score would be 0%, not 90%."

        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "/out/report.txt",
            isExportingReport: true,
            didSaveReport: true,
            scoreLine: "Mutation score: 90% (9 killed, 1 survived)",
            suspectWarning: warning
        )
        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "",
            isExportingReport: false,
            didSaveReport: false,
            scoreLine: "Mutation score: 90% (9 killed, 1 survived)",
            suspectWarning: warning
        )
        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "/out/report.txt",
            isExportingReport: true,
            didSaveReport: false,
            scoreLine: "Mutation score: 90% (9 killed, 1 survived)",
            suspectWarning: warning
        )

        // Only a saved report, which isn't printed, has its score said.
        XCTAssertEqual(printer.linesPassed, [
            "🏁 SwiftMutator finished running!",
            "📊 Mutation score: 90% (9 killed, 1 survived)",
            "📝 Report generated: \("/out/report.txt".bold)",
            "⚠️ \(warning)",
            "🏁 SwiftMutator finished running!",
            "📝 SwiftMutator's report\n\nthe report",
            "⚠️ \(warning)",
            "🏁 SwiftMutator finished running!",
            "the report",
            "\n",
            "Could not save report!",
            "⚠️ \(warning)",
        ])
        XCTAssertEqual(standardError.linesPassed, [])
    }
}
