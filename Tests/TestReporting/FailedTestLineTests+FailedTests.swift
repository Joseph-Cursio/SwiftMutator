@testable import muterCore
import XCTest

extension FailedTestLineTests {
    func test_failedTests_namesEachTestOnce_inTheOrderTheyFirstFailed() {
        let log = """
        ◇ Test run started.
        ✘ Test b() recorded an issue at B.swift:2:5: x
        ✘ Test a() recorded an issue at A.swift:1:5: y
        ✘ Test b() recorded an issue at B.swift:3:5: z
        ✘ Test b() failed after 0.001 seconds with 2 issues.
        Test Case '-[M.C testX]' failed (0.1 seconds).
        """

        XCTAssertEqual(
            FailedTestLine.failedTests(inLog: log),
            FailedTests(
                tests: [
                    FailedTest(name: "b()", location: "B.swift:2:5"),
                    FailedTest(name: "a()", location: "A.swift:1:5"),
                    FailedTest(name: "-[M.C testX]", location: nil),
                ],
                total: 3,
                firstLine: "✘ Test b() recorded an issue at B.swift:2:5: x"
            )
        )
    }

    // Swift Testing names a test by its function or display name only, so tests in different suites can share one.
    func test_failedTests_tellsSameNamedTestsInOtherFilesApart() {
        let log = """
        ✘ Test ignoresTestFiles() recorded an issue at GlobalStateTests.swift:40:9: x
        ✘ Test ignoresTestFiles() recorded an issue at GlobalStateTests.swift:41:9: y
        ✘ Test ignoresTestFiles() recorded an issue at PureFunctionTests.swift:52:9: z
        """

        let failures = FailedTestLine.failedTests(inLog: log)

        XCTAssertEqual(failures.tests, [
            FailedTest(name: "ignoresTestFiles()", location: "GlobalStateTests.swift:40:9"),
            FailedTest(name: "ignoresTestFiles()", location: "PureFunctionTests.swift:52:9"),
        ])
        XCTAssertEqual(failures.total, 2)
    }

    // A multi-line string argument goes on past the issue's line, and the location follows it, as in this real log.
    func test_failedTests_findsTheLocationAfterArgumentsThatSpanLines() {
        let firstLine = "✘ Test \"No issue for an implicit return\" recorded an issue with 1 argument source → "
            + "\"var doubled: [Int] {"
        let log = """
        \(firstLine)
            items.map { $0 * 2 }

        }" at MapUsedForSideEffectsVisitorTests.swift:105:9: Expectation failed: visitor.detectedIssues.isEmpty
        ↳ visitor.detectedIssues.isEmpty → false
        ✘ Test "No issue for an implicit return" recorded an issue with 1 argument source → "f()" at \
        MapUsedForSideEffectsVisitorTests.swift:105:9: x
        """

        XCTAssertEqual(
            FailedTestLine.failedTest(in: firstLine),
            FailedTest(name: "\"No issue for an implicit return\"", location: nil)
        )
        XCTAssertEqual(
            FailedTestLine.failedTests(inLog: log),
            FailedTests(
                tests: [
                    FailedTest(
                        name: "\"No issue for an implicit return\"",
                        location: "MapUsedForSideEffectsVisitorTests.swift:105:9"
                    ),
                ],
                total: 1,
                firstLine: firstLine
            )
        )
    }

    func test_failedTests_neverTakesALaterMessagesLocation_forArgumentsWithoutOne() {
        let log = """
        ✘ Test check(x:) recorded an issue with 1 argument x → 1: Caught error: E()
        output the test printed
        ↳ details at Details.swift:1:1: x
        ✘ Test other() recorded an issue at OtherTests.swift:3:3: x
        """

        XCTAssertEqual(FailedTestLine.failedTests(inLog: log).tests, [
            FailedTest(name: "check(x:)", location: nil),
            FailedTest(name: "other()", location: "OtherTests.swift:3:3"),
        ])
    }

    func test_failedTests_keepsAtMostTheLimit_butCountsThemAll() {
        let log = (1...25)
            .map { "✘ Test test\($0)() recorded an issue at T.swift:\($0):5: x" }
            .joined(separator: "\n")

        let failures = FailedTestLine.failedTests(inLog: log)

        XCTAssertEqual(FailedTestLine.killedByLimit, 20)
        XCTAssertEqual(failures.tests.map(\.name), (1...20).map { "test\($0)()" })
        XCTAssertEqual(failures.total, 25)
        XCTAssertEqual(FailedTestLine.failedTests(inLog: log, limit: 2).tests.map(\.name), ["test1()", "test2()"])
        XCTAssertEqual(FailedTestLine.failedTests(inLog: log, limit: 2).total, 25)
    }

    func test_failedTests_capsNamesAndTheFirstLine() {
        let longName = String(repeating: "n", count: 300) + "()"
        let line = "\(escape)[91m✘\(escape)[0m Test \(longName) recorded an issue at A.swift:1:1: "
            + String(repeating: "d", count: 600)

        let failures = FailedTestLine.failedTests(inLog: line)

        XCTAssertEqual(FailedTestLine.nameLengthLimit, 200)
        XCTAssertEqual(FailedTestLine.lineLengthLimit, 500)
        XCTAssertEqual(failures.tests, [FailedTest(name: String(longName.prefix(200)), location: "A.swift:1:1")])
        XCTAssertEqual(FailedTestLine.failedTest(in: line)?.name, String(longName.prefix(200)))
        XCTAssertEqual(failures.firstLine, String(FailedTestLine.withoutColours(line).prefix(500)))
        XCTAssertEqual(failures.firstLine?.count, 500)
    }

    func test_failedTests_ofAStoppedRun_isTheLineThatStoppedIt() {
        let stoppingLine = "✘ Test a() recorded an issue at A.swift:1:1: x"
        let killedLog = "◇ Test run started.\n"
            + "\(escape)[91m✘\(escape)[0m Test a() recorded an issue at A.swift:1:1: x\n◇ Test b() sta"
        let log = killedLog + MutationTestingDelegate.noteForRunStopped(at: stoppingLine, after: killedLog)

        XCTAssertEqual(
            FailedTestLine.failedTests(inLog: log),
            FailedTests(tests: [FailedTest(name: "a()", location: "A.swift:1:1")], total: 1, firstLine: stoppingLine)
        )
    }

    func test_failedTests_ofTheLogFixtures() {
        XCTAssertEqual(
            FailedTestLine.failedTests(
                inLog: loadLogFile(named: "testRunWithFailures_swiftTesting_multipleIssues.log")
            ).tests,
            [
                FailedTest(name: "addition()", location: "MathTests.swift:8:5"),
                FailedTest(name: "subtraction()", location: "MathTests.swift:14:5"),
            ]
        )

        let xctestFailures = FailedTestLine.failedTests(
            inLog: loadLogFile(named: "testRunWithFailures_withoutTestFailedFooter.log")
        )
        XCTAssertEqual(xctestFailures.total, 8)
        XCTAssertEqual(
            xctestFailures.tests.first,
            FailedTest(
                name: "-[muterTests.MutationTestingSpec performMutationTesting, "
                    + "performs mutation test for every mutation operator]",
                location: nil
            )
        )

        for name in [
            "testRunWithFailures_swift.log",
            "testRunWithFailures_swiftTesting.log",
            "testRunWithFailures_withTestFailedFooter.log",
            "testRunWithFailures_withTestFailedFooter_singleTestFailure.log",
            "timeout_xcodebuildFailedTestCase.log",
            "testRunWithoutFailures_swiftTesting.log",
            "testRunWithoutFailures_withTestSucceededFooter.log",
        ] {
            let log = loadLogFile(named: name)
            let failures = FailedTestLine.failedTests(inLog: log)
            XCTAssertEqual(failures.firstLine, FailedTestLine.first(inLog: log), name)
            XCTAssertEqual(failures.total == 0, failures.firstLine == nil, name)
        }
    }
}
