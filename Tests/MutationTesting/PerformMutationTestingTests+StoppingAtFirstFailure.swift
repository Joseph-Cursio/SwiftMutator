@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    func test_whenThePassingBaselinePrintsAFailureLikeLine_thenMutantsRunWithStoppingOff() async throws {
        let lookalike = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 1 == 2"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: true
        )
        // A test of a test reporter that prints a sample of its output, and passes.
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        \(lookalike)
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        let notices = sent().filter { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notices.count, 1)
        let reason = try XCTUnwrap(notices.first?.object as? String)
        XCTAssertTrue(reason.hasSuffix("\n  \(lookalike)"), reason)
        // Before the baseline's log, which starts the progress bar.
        XCTAssertEqual(sent().first?.name, .stopAtFirstFailureTurnedOff)
    }

    // A run also stops at a crash's line, so one a passing baseline prints turns stopping off too.
    func test_whenThePassingBaselinePrintsACrashLikeLine_thenMutantsRunWithStoppingOff() async throws {
        let lookalike = "error: Process '/p/Tests.xctest' exited with unexpected signal code 5"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: true
        )
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        \(lookalike)
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
        let reason = try XCTUnwrap(sent().first?.object as? String)
        XCTAssertTrue(reason.hasSuffix("looks like a failed test or a crash:\n  \(lookalike)"), reason)
    }

    // The line would also count a mutant whose run reaches the time limit after printing it as killed.
    func test_whenThePassingBaselinePrintsAFailureLikeLineWithoutStopping_thenItStillDoesNotCount() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: false
        )
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        ✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 1 == 2
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        // Runs weren't going to stop at a failed test, so nothing changed that is worth a notice.
        XCTAssertEqual(sent().count, 0)
    }

    // With the key unset: stopping at the first failed test is the default.
    func test_whenThePassingBaselineHasNoFailureLikeLine_thenMutantsStopAtTheirFirstFailure() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        ✔ Test sum() passed after 0.001 seconds.
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [true, true])
        XCTAssertEqual(sent().count, 0)
    }

    func test_whenStopAtFirstFailureIsSetForXcodebuild_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(
            named: [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )

        _ = try await sut.run(with: state)

        let names = sent().map(\.name)
        XCTAssertEqual(names.filter { $0 == .stopAtFirstFailureTurnedOff }.count, 1)
        // With the start of mutation testing, before the baseline's log starts the progress bar.
        XCTAssertEqual(
            Array(names.prefix(3)),
            [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )
        let reason = try XCTUnwrap(configuration.stopAtFirstFailureUnsupportedReason)
        let notice = sent().first { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notice?.object as? String, reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    func test_whenStopAtFirstFailureIsSetWithRepeatUntil_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--repeat-until", "pass"],
            stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent().count, 1)
        let reason = try XCTUnwrap(sent().first?.object as? String)
        XCTAssertEqual(reason, configuration.stopAtFirstFailureUnsupportedReason)
        XCTAssertTrue(reason.contains("--repeat-until"), reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    func test_whenStopAtFirstFailureIsUnset_thenNoNoticeIsSent() async throws {
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        // Only an explicit `true` asks for it, so a test command that can't use it is worth a notice only then.
        let configurations = [
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]),
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: false),
        ]
        for configuration in configurations {
            state.muterConfiguration = configuration
            ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(sent().count, 0)
    }
}
