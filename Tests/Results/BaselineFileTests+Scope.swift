import ArgumentParser
@testable import muterCore
import XCTest

extension BaselineFileTests {
    // `ProjectTree` leaves it out at the root, as it does the triage file, so committing a new one refuses no resume.
    func test_theProjectTree_leavesOutTheBaselineFileAtTheRoot() {
        XCTAssertTrue(ProjectTree.prunedAtRoot.contains("muter.baseline.yml"))
    }

    func test_theSameScope_isntRefused() throws {
        let baseline = file([])
        let same = BaselineScope(
            operators: ["RelationalOperatorReplacement", "SwapTernary", "SwapTernary"],
            skipCoverage: false,
            configuration: .init(
                arguments: ["test"],
                exclude: ["!/Stubs/", "/Generated/", "/Generated/"],
                mutationTestTimeout: 60.5
            )
        )

        XCTAssertNoThrow(try BaselineRefused.check(same, against: baseline, subject: "this run"))
    }

    // Every difference is said, each key by its own name; an `--exclude` adds to `exclude`, so it's another scope.
    func test_anotherScope_isRefused_namingEveryDifference() throws {
        let other = BaselineScope(
            operators: ["SwapTernary"],
            skipCoverage: true,
            configuration: .init(
                arguments: ["test", "--parallel"],
                buildSystem: "swift",
                coverageThreshold: 20,
                exclude: ["/Generated/", "!/Stubs/", "/Fixtures/"],
                excludeCalls: ["print"],
                mutationTestTimeout: nil
            )
        )

        XCTAssertThrowsError(try BaselineRefused.check(other, against: file([]), subject: "this run")) { error in
            let refused = error as? BaselineRefused
            XCTAssertEqual(refused?.reasons, [
                #"operators is ["RelationalOperatorReplacement","SwapTernary"] in the baseline file, and "#
                    + #"["SwapTernary"] in this run."#,
                "skipCoverage is false in the baseline file, and true in this run.",
                #"arguments is ["test"] in the baseline file, and ["test","--parallel"] in this run."#,
                #"buildSystem is not set in the baseline file, and "swift" in this run."#,
                "coverageThreshold is 0 in the baseline file, and 20 in this run.",
                #"exclude is ["!/Stubs/","/Generated/"] in the baseline file, and "#
                    + #"["!/Stubs/","/Fixtures/","/Generated/"] in this run."#,
                #"excludeCalls is [] in the baseline file, and ["print"] in this run."#,
                "mutationTestTimeout is 60.5 in the baseline file, and not set in this run.",
            ])
            XCTAssertTrue(
                "\(error)".hasSuffix("write a new baseline file with --write-baseline from a run of this scope.")
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .baselineRefused)
        }
    }

    // `executable` is an absolute path, which differs between machines, so it's never compared.
    func test_theScope_ofAConfiguration_leavesOutItsExecutable_andTakesItsFlags() {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], excludeList: ["/A/"])
            .overriding(workers: 4, timeout: 30, exclude: ["/B/"])
        let elsewhere = MuterConfiguration(executable: "/opt/bin/swift", arguments: ["test"], excludeList: ["/A/"])
            .overriding(workers: 1, timeout: 30, exclude: ["/B/"])

        let rorScope = BaselineScope(configuration: configuration, operators: [.ror], skipCoverage: false)

        XCTAssertEqual(rorScope.configuration.exclude, ["/A/", "/B/"])
        XCTAssertEqual(rorScope.configuration.mutationTestTimeout, 30)
        XCTAssertEqual(rorScope, BaselineScope(configuration: elsewhere, operators: [.ror], skipCoverage: false))
    }

    // `--exclude-calls` adds to `excludeCalls`, as `--exclude` adds to `exclude`, so a run that names the key's own
    // entry again, or moves an entry between the key and the flag, has the same scope.
    func test_theScope_takesExcludeCallsEntriesSorted_onceEach() throws {
        func runScope(key: [String], flag: [String]) -> BaselineScope {
            let configuration = MuterConfiguration(executable: "/swift", arguments: ["test"], excludeCallList: key)
                .overriding(workers: nil, timeout: nil, keys: KeyFlags(excludeCalls: flag))
            return BaselineScope(configuration: configuration, operators: [.ror], skipCoverage: false)
        }
        let keyOnly = runScope(key: ["log"], flag: [])
        let repeated = runScope(key: ["log"], flag: ["log"])

        XCTAssertEqual(repeated, keyOnly)
        XCTAssertEqual(runScope(key: ["b"], flag: ["a"]).configuration.excludeCalls, ["a", "b"])
        XCTAssertEqual(runScope(key: ["a"], flag: ["b"]), runScope(key: ["b"], flag: ["a"]))
        let baseline = BaselineFile(
            path: path, swiftMutator: "0.1.0", score: .init(killed: 1, scored: 2), scope: keyOnly, survivors: []
        )
        XCTAssertNoThrow(try BaselineRefused.check(repeated, against: baseline, subject: "this run"))
    }
}
