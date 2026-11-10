@testable import muterCore
import XCTest
import Yams

extension LoadConfigurationTests {
    // 0 was a limit of no time for every mutant, and below 0 trapped.
    func test_aTimeoutNotAboveZero_isRefused() async throws {
        for value in ["0", "-5"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeout: \(value)\n".utf8
            )

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(
                    reason,
                    "mutationTestTimeout must be a number of seconds above 0, and at most a day (86400), not \(value)."
                )
            }
        }
    }

    // It was taken as 1.
    func test_noWorkers_isRefused() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestWorkers: 0\n".utf8
        )

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error,
                .configurationParsingError(reason: "mutationTestWorkers must be a whole number, at least 1, not 0.")
            )
        }
    }

    // Each would break a call SwiftMutator makes with them: its build for testing, a mutant's run from the
    // `.xctestrun`, the coverage run, or the runs after the first that writes a result bundle.
    func test_xcodebuildArgumentsThatBreakSwiftMutatorsOwnCalls_areRefused_namingTheArgument() async throws {
        let refused: [(arguments: String, named: String)] = [
            ("[-destination, platform=macOS, build-for-testing]", "`build-for-testing` in `arguments`"),
            ("[-destination, platform=macOS, test-without-building]", "`test-without-building` in `arguments`"),
            ("[-destination, platform=macOS, analyze, test]", "`analyze` in `arguments` isn't an action"),
            ("[-destination, platform=macOS, archive]", "`archive` in `arguments` isn't an action"),
            ("[-xctestrun, App.xctestrun, -destination, platform=macOS, test]", "`-xctestrun` in `arguments`"),
            ("[-destination, platform=macOS, -testProductsPath, a.xctestproducts, test]", "`-testProductsPath`"),
            ("[-destination, platform=macOS, -resultBundlePath, out.xcresult, test]", "`-resultBundlePath`"),
            ("[-destination, platform=macOS, -enumerate-tests, test]", "`-enumerate-tests`"),
        ]
        for (arguments, named) in refused {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data("executable: /usr/bin/xcodebuild\narguments: \(arguments)\n".utf8)

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(reason.hasPrefix(named), "\(arguments): \(reason)")
            }
        }
    }

    func test_aBuildForTestingAction_isRefused_sayingWhatToDoInstead() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, build-for-testing]\n".utf8
        )

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error, .configurationParsingError(
                reason: "`build-for-testing` in `arguments` is an action SwiftMutator runs itself: it builds once with "
                    + "`build-for-testing`, then tests each mutant with `test-without-building`. Give `test` as the "
                    + "action instead."
            ))
        }
    }

    // A wrapper script is given the same arguments as xcodebuild.
    func test_aWrapperScriptForXcodebuild_hasItsArgumentsChecked() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("""
        executable: /project/ci/run-tests.sh
        buildSystem: xcodebuild
        arguments: [-destination, platform=macOS, -xctestrun, App.xctestrun, test-without-building]
        """.utf8)

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.hasPrefix("`-xctestrun` in `arguments`"), reason)
        }
    }

    // `clean test` cleans before the baseline and `build test` builds before it; a value that reads like an action, as
    // `-scheme archive`, is a value. The coverage run's `-enableCodeCoverage` replaces the test command's. Other build
    // systems' arguments aren't xcodebuild's.
    func test_argumentsThatSwiftMutatorsCallsTake_areLetThrough() async throws {
        let accepted = [
            "executable: /usr/bin/xcodebuild\narguments: [-scheme, archive, -destination, platform=macOS, clean, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, build, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, -enableCodeCoverage, NO, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, -only-testing:AppTests, test]",
            "executable: /usr/bin/swift\narguments: [build, test, -enableCodeCoverage]",
        ]
        for yaml in accepted {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(yaml.utf8)

            let result = try await sut.run(with: state)

            guard case .configurationParsed? = result.last else {
                XCTFail("\(yaml): \(result)")
                return
            }
        }
    }

    // The flags take their place, so the run never uses them.
    func test_aTimeoutAndWorkersOutOfRange_areLetThrough_whenTheFlagsReplaceThem() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeout: 0\nmutationTestWorkers: 0\n".utf8
        )
        state.runOptions = .make(workers: 2, timeout: 60)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.testSuiteTimeout, 60)
        XCTAssertEqual(configuration.mutationTestWorkers, 2)
    }
}
