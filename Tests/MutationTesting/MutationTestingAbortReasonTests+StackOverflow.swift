import XCTest

extension MutationTestingAbortReasonTests {
    // As `swift test` printed it for a real overflow: Swift Testing's thread gets SIGBUS on a Mac, and XCTest's main
    // thread SIGSEGV.
    func test_whenATestProcessDiedOfABadMemoryAccess_thenSayItsLikelyAStackOverflow_andWhatToDo() {
        for signal in [SIGBUS, SIGSEGV] {
            let line = "error: Process '/x/DeepTests --testing-library swift-testing' exited with unexpected "
                + "signal code \(signal)"

            let description = baselineFailure("Test run started.\n\u{1B}[1;31m\(line)\u{1B}[0m\nNote: failures\n")

            XCTAssertTrue(description.contains("a test process crashed, with no mutant switched on"), description)
            XCTAssertTrue(description.contains("  \(line)\n"), description)
            XCTAssertTrue(description.contains("First check that your tests pass in your unmutated"), description)
            XCTAssertTrue(description.contains("the likely reason is a stack overflow"), description)
            XCTAssertTrue(description.contains("Thread stack size exceeded"), description)
            XCTAssertTrue(description.contains("\"exclude\" option"), description)
            XCTAssertTrue(description.contains("// muter:disable"), description)
            XCTAssertFalse(description.contains("misconfiguring"), description)
            XCTAssertTrue(description.contains("Here's the log your test command produced"), description)
        }
    }

    func test_anOlderSwiftPMsSignalLine_isReadToo() {
        XCTAssertTrue(baselineFailure("error: Exited with signal code \(SIGSEGV)\n").contains("likely reason"))
    }

    // Another target's crash can come first in the log.
    func test_aBadMemoryAccessAfterAnotherCrash_isTheOneNamed() {
        let log = "error: Exited with signal code \(SIGABRT)\nerror: Exited with signal code \(SIGBUS)\n"

        XCTAssertTrue(baselineFailure(log).contains("  error: Exited with signal code \(SIGBUS)\n"))
    }

    // xcodebuild gives no signal, and restarts after a timeout as well as a crash.
    func test_whenXcodebuildRestartedAfterACrash_thenSayItMayBeAStackOverflow() {
        let line = "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous"

        let description = baselineFailure("Test Case 'x' started.\n\(line) launches.\n")

        XCTAssertTrue(description.contains("  \(line) launches.\n"), description)
        XCTAssertTrue(description.contains("one possible reason is a stack overflow"), description)
    }

    func test_otherFailures_arentTakenForAStackOverflow() {
        for log in [
            "error: Exited with signal code \(SIGABRT)\n", // a trap, as a failed precondition or fatalError
            "error: Exited with signal code \(SIGILL)\n",
            "error: Exited with signal code 9\n",
            "a test printed: error: Exited with signal code \(SIGBUS)\n",
            "printed Restarting after unexpected exit, crash, or test timeout\n",
            "Test Case 'x' failed (0.1 seconds).\n",
        ] {
            let description = baselineFailure(log)
            XCTAssertFalse(description.contains("stack overflow"), log)
            XCTAssertTrue(description.contains("misconfiguring"), log)
        }
    }
}
