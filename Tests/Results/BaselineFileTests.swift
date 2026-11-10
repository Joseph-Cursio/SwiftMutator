import ArgumentParser
@testable import muterCore
import XCTest

/// The baseline file: what it saves, in what order, what it reads back, what it refuses, and the scopes it refuses.
final class BaselineFileTests: MuterTestCase {
    private var directory = ""
    private var path: String { "\(directory)/\(BaselineFile.fileName)" }

    private let scope = BaselineScope(
        operators: ["SwapTernary", "RelationalOperatorReplacement"],
        skipCoverage: false,
        configuration: .init(
            arguments: ["test"],
            coverageThreshold: 0,
            exclude: ["/Generated/", "!/Stubs/"],
            mutationTestTimeout: 60.5
        )
    )

    private func key(_ path: String, _ line: Int, _ column: Int = 9, occurrence: Int = 0) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: .ror, line: line, column: column, occurrence: occurrence)
    }

    private func file(_ survivors: [BaselineSurvivor], at path: String? = nil) -> BaselineFile {
        BaselineFile(
            path: path ?? self.path,
            swiftMutator: "0.1.0",
            score: .init(killed: 812, scored: 1_003),
            scope: scope,
            survivors: survivors
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    private func load(_ text: String) throws -> BaselineFile {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return try BaselineFile.load(at: path, using: FileManager.default)
    }

    private func assertRefused(_ text: String, saying words: String, line: UInt = #line) {
        XCTAssertThrowsError(try load(text), line: line) { error in
            XCTAssertTrue(error is BaselineRefused, "\(error)", line: line)
            XCTAssertTrue("\(error)".contains(words), "\(error)", line: line)
            XCTAssertTrue("\(error)".contains(path), "names the file: \(error)", line: line)
        }
    }

    private var minimal: String {
        """
        formatVersion: 1
        swiftMutator: 0.1.0
        score:
          killed: 1
          scored: 2
        scope:
          operators: [SwapTernary]
          skipCoverage: false
          configuration:
            arguments: [test]
            coverageThreshold: 0
            exclude: []
            excludeCalls: []
        survivors: []
        """
    }

    func test_aSavedFile_readsBackTheSame() throws {
        let saved = file([
            BaselineSurvivor(
                mutant: key("Sources/B.swift", 3),
                outcome: .timedOut,
                before: "<",
                after: "<=",
                line: "if count < limit {"
            ),
            BaselineSurvivor(mutant: key("Sources/A.swift", 9), outcome: .notCovered, before: "'a'", after: "\"b\""),
            // Text YAML would read as another type, or as a comment or a mapping, reads back as it was.
            BaselineSurvivor(
                mutant: key("Sources/C.swift", 1),
                outcome: .survived,
                before: "true",
                after: "1",
                line: "let x: [String: Int] = [:] # null ~ - { }"
            ),
        ])

        XCTAssertTrue(saved.save(using: FileManager.default))
        let read = try BaselineFile.load(at: path, using: FileManager.default)

        XCTAssertEqual(read.formatVersion, BaselineFile.formatVersion)
        XCTAssertEqual(read.swiftMutator, "0.1.0")
        XCTAssertEqual(read.score, .init(killed: 812, scored: 1_003))
        XCTAssertEqual(read.scope, scope)
        XCTAssertEqual(read.survivors, saved.sortedSurvivors)
    }

    // By path, line, column, operator and repeat, so a commit's diff shows only what changed; the keys in the order a
    // reader wants them, and numbers as a person writes them.
    func test_aSave_isSorted_andReadsWell() throws {
        let survivors = [
            BaselineSurvivor(mutant: key("Sources/B.swift", 3), outcome: .survived, before: "<", after: "<="),
            BaselineSurvivor(mutant: key("Sources/A.swift", 10), outcome: .survived, before: "<", after: "<="),
            BaselineSurvivor(
                mutant: key("Sources/A.swift", 9, occurrence: 1),
                outcome: .survived,
                before: "<",
                after: "<="
            ),
            BaselineSurvivor(mutant: key("Sources/A.swift", 9), outcome: .survived, before: "<", after: "<="),
        ]

        let text = try file(survivors).yaml()

        XCTAssertTrue(text.hasPrefix(BaselineFile.introduction + "\nformatVersion: 1\nswiftMutator: 0.1.0\n"), text)
        let mutants = text.components(separatedBy: "\n").filter { $0.hasPrefix("- mutant:") }
        XCTAssertEqual(mutants, [
            "- mutant: Sources/A.swift:9:9 RelationalOperatorReplacement",
            "- mutant: Sources/A.swift:9:9 RelationalOperatorReplacement (#2)",
            "- mutant: Sources/A.swift:10:9 RelationalOperatorReplacement",
            "- mutant: Sources/B.swift:3:9 RelationalOperatorReplacement",
        ])
        XCTAssertTrue(text.contains("    mutationTestTimeout: 60.5\n"), text)
        XCTAssertTrue(text.contains("    coverageThreshold: 0\n"), text)
        XCTAssertTrue(text.contains("    exclude:\n    - '!/Stubs/'\n    - /Generated/\n"), text)
        XCTAssertTrue(text.contains("  operators:\n  - RelationalOperatorReplacement\n  - SwapTernary\n"), text)
    }

    // YAML folds a long value over lines by default, which a change to its code would make a diff of several.
    func test_aLongLine_isSavedOnOneLine_andReadsBackTheSame() throws {
        let line = "let decimalExponent = { (s, m) in Int(m) * (s == .minus ? -1 : 1) } <^> floatingPointE *> sign "
            + "<&> UInt.parser"
        let survivor = BaselineSurvivor(
            mutant: key("Sources/A.swift", 9),
            outcome: .survived,
            before: "*",
            after: "/",
            line: line
        )

        XCTAssertTrue(try file([survivor]).yaml().contains("  line: '\(line)'\n"))
        XCTAssertTrue(file([survivor]).save(using: FileManager.default))
        XCTAssertEqual(try BaselineFile.load(at: path, using: FileManager.default).survivors, [survivor])
    }

    // A shell leaves `~` alone in quotes; missing folders are made, as for a report.
    func test_aSave_expandsATilde_andMakesItsFolders() throws {
        let nested = "\(directory)/out/ci/\(BaselineFile.fileName)"
        XCTAssertTrue(file([], at: nested).save(using: FileManager.default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))

        XCTAssertEqual(URL.expandingTilde("~/b.yml"), NSHomeDirectory() + "/b.yml")
    }

    func test_aMinimalFile_reads() throws {
        let read = try load(minimal)

        XCTAssertEqual(read.survivors, [])
        XCTAssertNil(read.scope.configuration.mutationTestTimeout)
        XCTAssertNil(read.scope.configuration.buildSystem)
    }

    func test_noFile_isRefused_sayingHowToWriteOne() {
        XCTAssertThrowsError(try BaselineFile.load(at: path, using: FileManager.default)) { error in
            XCTAssertEqual(
                "\(error)",
                "SwiftMutator won't compare the survivors with the baseline file \(Logger.shellQuoted(path)):\n"
                    + "  - There is no baseline file there. Write one with --write-baseline."
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .baselineRefused)
        }
    }

    func test_textThatIsntUTF8_isRefused() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try BaselineFile.load(at: path, using: FileManager.default)) { error in
            XCTAssertTrue("\(error)".contains("It isn't UTF-8."), "\(error)")
        }
    }

    func test_anUnknownKey_atAnyDepth_isRefused() {
        assertRefused(minimal + "\ncolour: red", saying: "colour isn't a key of the file: give formatVersion")
        assertRefused(
            minimal.replacingOccurrences(of: "  scored: 2", with: "  scored: 2\n  score: 3"),
            saying: "score isn't a key of score: give killed, scored."
        )
        assertRefused(
            minimal.replacingOccurrences(of: "  skipCoverage: false", with: "  skipCoverage: false\n  shard: 1/2"),
            saying: "shard isn't a key of scope"
        )
        assertRefused(
            minimal.replacingOccurrences(of: "    excludeCalls: []", with: "    excludeCalls: []\n    executable: x"),
            saying: "executable isn't a key of scope.configuration"
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: "survivors:\n- mutant: A.swift:1:2 SwapTernary\n  outcome: survived\n  before: a\n  after: b\n"
                    + "  label: x"
            ),
            saying: "label isn't a key of a survivor's entry"
        )
    }

    func test_aNewerFormat_isRefused() {
        assertRefused(
            minimal.replacingOccurrences(of: "formatVersion: 1", with: "formatVersion: 2\nsomethingNew: true"),
            saying: "Its format is version 2, newer than this SwiftMutator reads (1)."
        )
    }

    func test_aMissingKey_orAWrongValue_isRefused() {
        assertRefused(
            minimal.replacingOccurrences(of: "swiftMutator: 0.1.0\n", with: ""),
            saying: "It isn't a baseline file SwiftMutator can read"
        )
        assertRefused("- a\n- b\n", saying: "It isn't a baseline file SwiftMutator can read")
        let entry = "survivors:\n- mutant: %@\n  outcome: %@\n  before: a\n  after: b\n"
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1", "survived")
            ),
            saying: "A.swift:1 isn't a whole mutant key"
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1:2 SwapTernary", "lived")
            ),
            saying: "has the outcome lived: give survived, timedOut or notCovered."
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1:2 SwapTernary", "survived")
                    + String(format: entry, "A.swift:1:2 SwapTernary", "survived")
                        .replacingOccurrences(of: "survivors:\n", with: "")
            ),
            saying: "A.swift:1:2 SwapTernary is listed more than once."
        )
    }

    // A hand edit can leave counts no run gives, whose score `--max-score-drop` would compare as if a run gave it.
    func test_aScoreNoRunGives_isRefused() {
        let counted = { (killed: Int, scored: Int) in
            self.minimal.replacingOccurrences(
                of: "  killed: 1\n  scored: 2",
                with: "  killed: \(killed)\n  scored: \(scored)"
            )
        }
        for (killed, scored) in [(900, 800), (-1, 2), (1, -5), (-3, -5)] {
            assertRefused(
                counted(killed, scored),
                saying: "Its score counts killed \(killed) of \(scored) scored: give scored from 0 up, and killed "
                    + "from 0 to scored."
            )
        }
        XCTAssertNoThrow(try load(counted(0, 0)))
        XCTAssertNoThrow(try load(counted(2, 2)))
    }

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

        let scope = BaselineScope(configuration: configuration, operators: [.ror], skipCoverage: false)

        XCTAssertEqual(scope.configuration.exclude, ["/A/", "/B/"])
        XCTAssertEqual(scope.configuration.mutationTestTimeout, 30)
        XCTAssertEqual(scope, BaselineScope(configuration: elsewhere, operators: [.ror], skipCoverage: false))
    }

    // The score's counts, as `ScoreGate` takes them, and every mutant the tests didn't kill.
    func test_aRunsBaselineFile_holdsItsSurvivors_andItsScoresCounts() {
        let outcome = MutationTestOutcome(mutations: [
            .make(testSuiteOutcome: .passed, key: key("A.swift", 1)),
            .make(testSuiteOutcome: .timeout, key: key("A.swift", 2)),
            .make(testSuiteOutcome: .noCoverage, key: key("A.swift", 3)),
            .make(testSuiteOutcome: .failed, key: key("A.swift", 4)),
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 5)),
        ])

        let made = BaselineFile(of: outcome, scope: scope, version: "9.9", path: "b.yml") { _ in nil }

        XCTAssertEqual(made.survivors.map(\.outcome), [.survived, .timedOut, .notCovered])
        XCTAssertEqual(made.survivors.map(\.mutant.line), [1, 2, 3])
        XCTAssertEqual(made.score, .init(killed: 1, scored: 4))
        XCTAssertEqual(made.swiftMutator, "9.9")
        XCTAssertEqual(made.path, "b.yml")
    }

    // Only a whole run's results make one, and a run that leaves some mutants out says why.
    func test_resultsThatLeaveMutantsOut_makeNoBaselineFile() {
        var whole = MutationTestOutcome(mutations: [.make(testSuiteOutcome: .passed, key: key("A.swift", 1))])
        whole.baselineScope = scope
        let target = "\(directory)/b.yml"

        XCTAssertEqual(
            BaselineFileSaving.save(whole, to: target, version: "0.1.0", using: FileManager.default),
            .saved(path: target)
        )

        var since = whole
        since = MutationTestOutcome(mutations: whole.mutations, since: .make())
        since.baselineScope = scope
        var files = whole
        files.filesToMutate = ["Sources/A.swift"]
        let cases: [(MutationTestOutcome, String)] = [
            (MutationTestOutcome(mutations: whole.mutations, mutant: "A.swift:1:9 SwapTernary"), "(--mutant)"),
            (
                MutationTestOutcome(
                    mutations: whole.mutations,
                    shards: ShardScope(indices: [1], count: 2, mutantsInAllShards: 4)
                ),
                "the results are only shard 1 of 2's"
            ),
            (since, "the code --since chose"),
            (files, "--files-to-mutate"),
            (MutationTestOutcome(mutations: whole.mutations, sampleIsCutShort: true), "didn't test every mutant"),
        ]
        for (outcome, words) in cases {
            let saving = BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default)
            guard case let .leftOut(_, reason) = saving else { return XCTFail("\(saving)") }
            XCTAssertTrue(reason.contains(words), reason)
            XCTAssertTrue(saving.plainLine.hasSuffix("and a baseline file holds a whole run's survivors."))
        }
        let stopped = BaselineFileSaving.save(
            whole, to: target, version: "0.1.0", unless: "the run didn't finish", using: FileManager.default
        )
        XCTAssertEqual(
            stopped.plainLine,
            "No baseline file was saved to \(target): the run didn't finish, and a baseline file holds a whole run's "
                + "survivors."
        )
    }

    // Compile recovery takes every mutant out of the build and the run finishes, but it tested none: its file would
    // record no survivor, and every survivor of a later run would be new.
    func test_aRunWhoseEveryMutantWasABuildError_makesNoBaselineFile() {
        var outcome = MutationTestOutcome(mutations: [
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 1)),
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 2)),
        ])
        outcome.baselineScope = scope
        let target = "\(directory)/b.yml"

        let saving = BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default)

        XCTAssertEqual(
            saving,
            .leftOut(path: target, because: "every mutant was a build error, so none was tested")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        let killed = MutationTestOutcome.Mutation.make(testSuiteOutcome: .failed, key: key("A.swift", 3))
        outcome = MutationTestOutcome(mutations: outcome.mutations + [killed])
        outcome.baselineScope = scope
        XCTAssertEqual(
            BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default),
            .saved(path: target)
        )
    }
}
