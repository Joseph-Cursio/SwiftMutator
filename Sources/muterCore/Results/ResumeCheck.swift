import Foundation

/// How the last session a results file recorded differs from the run that would resume it: what refuses the resume,
/// what only `--force-resume` lets through, and what changed that no result depends on. The project's files are
/// compared apart, by `ProjectTree.changes(since:)`, and coverage once it is gathered, by `coverageChange`.
enum ResumeCheck {
    /// Configuration keys no recorded outcome depends on: a change is only said, though some choose which kills a later
    /// session tests again alone (`keysThatChooseKillsToTestAgain`). Where one worker tests, on the destination or
    /// on a simulator of its own (`oneWorkerSimulator`), can change a kill's kind, but not whether it is killed.
    /// `failUnder` judges the score once the run finishes, never a result, and `propertyTests` only splits the kills
    /// the reports count, which `propertyTestFilter`'s runs only settle.
    /// The keys that choose the operators, which `selectionDifferences` compares, however they were chosen. So a change
    /// of these keys that chooses the same operators is no difference, and one that doesn't is said once.
    static let keysComparedByTheirSelection: Set = [
        MuterConfiguration.CodingKeys.operators.stringValue,
        MuterConfiguration.CodingKeys.skipOperators.stringValue,
    ]

    /// Those of `keysThatDontAffectOutcomes` that change no result recorded, but do choose which kills are tested again
    /// alone, so can change what a later session makes of a kill.
    static let keysThatChooseKillsToTestAgain: Set = [
        MuterConfiguration.CodingKeys.suspectTestFilePercent.stringValue,
        MuterConfiguration.CodingKeys.suspectTestMinimumFiles.stringValue,
        MuterConfiguration.CodingKeys.controlRunEvery.stringValue,
        MuterConfiguration.CodingKeys.suspectKillReruns.stringValue,
    ]

    static let keysThatDontAffectOutcomes: Set = [
        MuterConfiguration.CodingKeys.mutationTestWorkers.stringValue,
        MuterConfiguration.CodingKeys.workersShareBuild.stringValue,
        MuterConfiguration.CodingKeys.stopAtFirstFailure.stringValue,
        MuterConfiguration.CodingKeys.buildTimeout.stringValue,
        MuterConfiguration.CodingKeys.oneWorkerSimulator.stringValue,
        MuterConfiguration.CodingKeys.suspectTestFilePercent.stringValue,
        MuterConfiguration.CodingKeys.suspectTestMinimumFiles.stringValue,
        MuterConfiguration.CodingKeys.controlRunEvery.stringValue,
        MuterConfiguration.CodingKeys.suspectKillReruns.stringValue,
        MuterConfiguration.CodingKeys.keepAllLogs.stringValue,
        MuterConfiguration.CodingKeys.keepLogFolders.stringValue,
        MuterConfiguration.CodingKeys.failUnder.stringValue,
        MuterConfiguration.CodingKeys.propertyTests.stringValue,
        MuterConfiguration.CodingKeys.propertyTestFilter.stringValue,
    ]

    /// The key of a mutant's time limit, `mutationTestTimeout`, which a resume or a reuse lets lengthen
    /// (`isALongerTimeLimit`).
    static let timeLimitKey = MuterConfiguration.CodingKeys.testSuiteTimeout.stringValue

    /// What the resuming run would record in its header, of what a resume compares.
    struct Current: Equatable {
        /// As loaded, as a header records it.
        let configuration: MuterConfiguration
        /// By name.
        let operators: [String]
        let filesToMutate: [String]
        let skipCoverage: Bool
        let usingTestPlan: Bool
        let provenance: Provenance
        /// The SHA-256 of the test plan's file, as read; nil without a plan, or for a header that didn't record it.
        var testPlanSHA256: String?
        /// What `--since` chose; nil without it.
        var since: ChangeSelection?
        /// `--shard`; nil without it.
        var shard: Shard?
        /// `--sample` and its seed; nil without it.
        var sample: Sample?
        /// The key of the mutant `--mutant` chose, as its description; nil without it, and until it is chosen.
        var mutant: String?
    }

    /// A value the recorded session had and this run has, each as sorted-keys JSON. nil is a configuration key that
    /// isn't set, or a build or toolchain identity that couldn't be read. `name` is the value's key in the header.
    struct Difference: Equatable {
        let name: String
        let was: String?
        let isNow: String?
    }

    /// What a recorded session is compared with the current one for, which decides what is compared.
    enum Purpose {
        /// `--resume`: everything.
        case resume
        /// `--reuse`: neither what `--since` chose, nor the shard, nor the sample. A result holds whichever other
        /// mutants are tested, and a reuse keeps only those of the mutants it discovers.
        case reuse
        /// Merging a split's shards (`report`): everything but the shard, in which shards differ. The sample too, which
        /// the shards of a sampled split share.
        case merge
    }

    struct Verdict: Equatable {
        var refusals: [ResumeRefusal] = []
        /// The names of the build and toolchain differences that `--force-resume` let through.
        var forced: [String] = []
        /// A sentence for each change no result depends on.
        var notices: [String] = []
    }

    /// How the coverage a resumed run gathered differs from the coverage the last session recorded. Discovery leaves
    /// out the files and the code no test runs, and without coverage leaves out nothing, so a change is the likeliest
    /// reason the two sessions discover different mutants. Never refuses: a kept result doesn't depend on coverage, and
    /// no flag could bring back the last session's.
    enum CoverageChange: Equatable, CustomStringConvertible {
        /// Coverage couldn't be gathered in the last session, which then discovered every mutant, and is now.
        case gatheredOnlyNow
        /// Coverage was gathered in the last session, and couldn't be now, so this run discovers every mutant.
        case gatheredOnlyThen
        /// The files without coverage, compared as sets: whatever the percent did.
        case filesWithoutCoverageChanged
        /// Only the percent.
        case percentChanged(was: Int, isNow: Int)

        /// Whether one of the two sessions has coverage and the other doesn't.
        var isGatheredInOneSessionOnly: Bool {
            self == .gatheredOnlyNow || self == .gatheredOnlyThen
        }

        /// Whether the change can leave out mutants the last session discovered: any but coverage this run couldn't
        /// gather, without which discovery leaves out nothing.
        var canLeaveOutMutants: Bool {
            self != .gatheredOnlyThen
        }

        /// Whether the change can bring in mutants the last session left out: any but coverage the last session
        /// couldn't gather, without which it left out nothing.
        var canBringInMutants: Bool {
            self != .gatheredOnlyNow
        }

        /// "coverage couldn't be gathered then, and is now": a lowercase clause, to follow a colon or a conjunction, or
        /// to start a sentence once capitalized.
        var description: String {
            switch self {
            case .gatheredOnlyNow:
                return "coverage couldn't be gathered then, and is now"
            case .gatheredOnlyThen:
                return "coverage was gathered then, and couldn't be now"
            case .filesWithoutCoverageChanged:
                return "the files without coverage changed"
            case let .percentChanged(was, isNow):
                return "coverage was \(was)% and is \(isNow)% now"
            }
        }
    }

    /// Compared: every configuration key but `keysThatDontAffectOutcomes` and `keysComparedByTheirSelection`; the
    /// operators, `filesToMutate` (both as sets),
    /// `skipCoverage` and `--mutant`'s mutant; and what identifies the SwiftMutator build, the toolchain and the
    /// SDK. Not compared: SwiftMutator's version and path, which its SHA-256 covers; the process, host and arguments;
    /// and the effective `timeoutSeconds`, `stopsAtFirstFailure` and `failedTestLinesAreReliable`, which follow from
    /// the configuration, the baseline and the timed test run. Only the build and toolchain differences are ever
    /// `forced`. Whether a test plan was tested, and which, is compared too (`testPlanRefusals`).
    ///
    /// A resume compares what `--since` compares the working tree with too: the merge base, and `--changed-lines`; the
    /// shard; and the sample. What `purpose` leaves out isn't compared.
    ///
    /// A resume or a reuse lets through a time limit at least as long as `longestLimit`, the longest any of the file's
    /// results was tested under (`isALongerTimeLimit`); nil, when that isn't known, or for a merge, lets none through.
    static func compare(
        _ recorded: ResultsHeader,
        with current: Current,
        forcing: Bool,
        for purpose: Purpose = .resume,
        longestLimit: Double? = nil
    ) -> Verdict {
        var verdict = Verdict()
        for difference in configurationDifferences(recorded.configuration, current.configuration)
            where !keysComparedByTheirSelection.contains(difference.name) {
            judge(difference, into: &verdict, for: purpose, longestLimit: longestLimit)
        }
        verdict.refusals += selectionDifferences(recorded, current).map(ResumeRefusal.selectionChanged)
        if purpose != .reuse {
            verdict.refusals += sinceDifferences(recorded.since, current.since).map(ResumeRefusal.selectionChanged)
        }
        if purpose == .resume, let shard = shardDifference(recorded.shard, current.shard) {
            verdict.refusals.append(.selectionChanged(shard))
        }
        if purpose != .reuse, let sample = sampleDifference(recorded.sample, current.sample) {
            verdict.refusals.append(.selectionChanged(sample))
        }
        verdict.refusals += testPlanRefusals(recorded, current)
        let builds = provenanceDifferences(
            recorded.provenance,
            current.provenance,
            testCommand: current.configuration.testCommandExecutable
        )
        if forcing {
            verdict.forced = builds.map(\.name)
        } else {
            verdict.refusals += builds.map(ResumeRefusal.needsForce)
        }
        return verdict
    }

    /// Each key's value as sorted-keys JSON, both sides encoded through MuterConfiguration (whose decoder turns an Int
    /// timeout into a Double), over the union of the keys either side has: a new key is compared by default. Sorted
    /// by key.
    static func configurationDifferences(
        _ recorded: MuterConfiguration,
        _ current: MuterConfiguration
    ) -> [Difference] {
        // A side that can't be encoded has no keys, so every key the other has differs.
        let was = values(of: recorded)
        let isNow = values(of: current)
        return Set(was.keys).union(isNow.keys).sorted().compactMap { name in
            was[name] == isNow[name] ? nil : Difference(name: name, was: was[name], isNow: isNow[name])
        }
    }

    /// How coverage changed from the last session's `recorded` summary, gathered in the project copy at
    /// `recordedCopy`, to this run's `current` one, gathered in the copy at `currentCopy`; nil if it didn't. nil is a
    /// session without coverage: it couldn't be gathered, or `skipCoverage`, which `compare` refuses to change, skipped
    /// it in both. xcodebuild names the files without coverage by their absolute path in the copy, so they are compared
    /// by their path in it (`RepoRelativePath`), as a project that moved still has the same ones.
    static func coverageChange(
        from recorded: CoverageSummary?,
        in recordedCopy: URL,
        to current: CoverageSummary?,
        in currentCopy: URL
    ) -> CoverageChange? {
        switch (recorded, current) {
        case (nil, nil):
            return nil
        case (nil, _?):
            return .gatheredOnlyNow
        case (_?, nil):
            return .gatheredOnlyThen
        case let (recorded?, current?):
            let recordedFiles = Set(recorded.filesWithoutCoverage.map { RepoRelativePath.of($0, under: recordedCopy) })
            let currentFiles = Set(current.filesWithoutCoverage.map { RepoRelativePath.of($0, under: currentCopy) })
            if recordedFiles != currentFiles {
                return .filesWithoutCoverageChanged
            }
            return recorded.percent == current.percent
                ? nil
                : .percentChanged(was: recorded.percent, isNow: current.percent)
        }
    }

    /// Says `difference`, a configuration key's, in `verdict`: a notice for a key no result depends on, or for a
    /// longer time limit that `purpose` lets through; a refusal otherwise, which for a new limit with no `longest` to
    /// compare it with says so.
    private static func judge(
        _ difference: Difference,
        into verdict: inout Verdict,
        for purpose: Purpose,
        longestLimit: Double?
    ) {
        if keysThatDontAffectOutcomes.contains(difference.name) {
            let effect = keysThatChooseKillsToTestAgain.contains(difference.name)
                ? "which no recorded result depends on, though it chooses which kills are tested again alone"
                : "which no result depends on"
            verdict.notices.append("\(difference.name) \(difference.change(absent: "not set")), \(effect).")
        } else if purpose == .merge || difference.name != timeLimitKey {
            verdict.refusals.append(.configurationChanged(difference))
        } else if isALongerTimeLimit(difference, thanEvery: longestLimit) {
            verdict.notices.append(
                "\(difference.name) \(difference.change(absent: "not set")), no shorter than any session's "
                    + "limit: the timeouts under a shorter one are tested again."
            )
        } else if longestLimit == nil, difference.isNow != nil {
            verdict.refusals.append(.timeLimitUnknown(difference))
        } else {
            verdict.refusals.append(.configurationChanged(difference))
        }
    }

    /// Whether `difference` sets the time limit to at least `longest`, the longest a session tested under: every result
    /// then holds under it, as a run that ended in time still does, but a timeout under a shorter limit, which the plan
    /// tests again (`ResumePlan.Reason.timeoutUnderShorterLimit`). Not a limit no longer set, whose default only the
    /// baseline, after this check, sets; nor any, with no `longest` to compare it with.
    private static func isALongerTimeLimit(_ difference: Difference, thanEvery longest: Double?) -> Bool {
        guard difference.name == timeLimitKey, let longest, let isNow = difference.isNow.flatMap(Double.init) else {
            return false
        }
        return isNow >= longest
    }

    /// What refuses `current` the results `recorded` tested: a run of a test plan only continues one of the same plan,
    /// byte for byte, and a run without a plan one without, whose files a header from before `--resume` doesn't record.
    /// No `--force-resume` lets a changed plan through: its mutants may not be the ones the results are for. A plan
    /// made again of the same sources is the same bytes, so it is the same plan, and the check of its copy decides.
    private static func testPlanRefusals(_ recorded: ResultsHeader, _ current: Current) -> [ResumeRefusal] {
        switch (recorded.usingTestPlan, current.usingTestPlan) {
        case (false, false):
            return recorded.project == nil ? [.noProjectTree] : []
        case (true, true):
            guard let plan = recorded.testPlan else { return [.testPlanNotRecorded] }
            guard plan.sha256 != current.testPlanSHA256 else { return [] }
            return [
                .testPlanChanged(
                    Difference(
                        name: "testPlan.sha256",
                        was: json(plan.sha256),
                        isNow: current.testPlanSHA256.flatMap { json($0) }
                    )
                ),
            ]
        case (true, false), (false, true):
            return [.testPlanRun(recordedUsedOne: recorded.usingTestPlan)]
        }
    }

    /// The differences in which mutants are tested. A run of one mutant (`--mutant`) differs from any other, so no
    /// whole run continues it, whatever the purpose.
    private static func selectionDifferences(_ recorded: ResultsHeader, _ current: Current) -> [Difference] {
        [
            difference("operators", Set(recorded.operators).sorted(), Set(current.operators).sorted()),
            difference("filesToMutate", Set(recorded.filesToMutate).sorted(), Set(current.filesToMutate).sorted()),
            difference("skipCoverage", recorded.skipCoverage, current.skipCoverage),
            recorded.mutant == current.mutant ? nil : Difference(
                name: "mutant",
                was: recorded.mutant.flatMap { json($0) },
                isNow: current.mutant.flatMap { json($0) }
            ),
        ].compactMap { $0 }
    }

    /// The differences in what `--since` compares the working tree with, by their keys in the header's `since`: its
    /// merge base, and `--changed-lines`. Not the ref as given, as one that moved since names another merge base; nor
    /// the files and lines it chose, which follow from the working tree: a changed file is compared as the project's
    /// files are, and its mutants tested again, and a mutant no longer chosen is a mutant no longer discovered.
    private static func sinceDifferences(_ recorded: ChangeSelection?, _ current: ChangeSelection?) -> [Difference] {
        switch (recorded, current) {
        case (nil, nil):
            return []
        case let (recorded?, current?):
            return [
                difference("since.mergeBase", recorded.mergeBase, current.mergeBase),
                difference("since.changedLines", recorded.changedLines, current.changedLines),
            ].compactMap { $0 }
        default:
            return [
                Difference(
                    name: "since",
                    was: recorded.flatMap { json($0.ref) },
                    isNow: current.flatMap { json($0.ref) }
                ),
            ]
        }
    }

    /// The difference in which shard is tested, by its `k/n`, which says all there is: which of the mutants discovered
    /// are in a shard follows from their places alone.
    private static func shardDifference(_ recorded: ShardSelection?, _ current: Shard?) -> Difference? {
        guard recorded?.shard != current else { return nil }
        return Difference(
            name: "shard",
            was: recorded.flatMap { json($0.shard.description) },
            isNow: current.flatMap { json($0.description) }
        )
    }

    /// The difference in which sample is tested, by its size and seed, which say all there is: which of the mutants
    /// discovered are in a sample follows from their places alone. Its value is "N, seed S".
    private static func sampleDifference(_ recorded: SampleSelection?, _ current: Sample?) -> Difference? {
        let was = recorded.map { "\($0.size), seed \($0.seed)" }
        let isNow = current.map { "\($0.size), seed \($0.seed)" }
        guard was != isNow else { return nil }
        return Difference(name: "sample", was: was.flatMap { json($0) }, isNow: isNow.flatMap { json($0) })
    }

    /// The differences in what identifies the SwiftMutator build, the toolchain and the SDK, named by their keys in
    /// the header's `provenance`. An identity that couldn't be read is a difference even if it is unknown on both
    /// sides, as nothing shows the two to be the same: SwiftMutator's SHA-256, and the test command's version, or,
    /// for a test command other than `swift` or `xcodebuild`, its SHA-256.
    private static func provenanceDifferences(
        _ recorded: Provenance,
        _ current: Provenance,
        testCommand: String
    ) -> [Difference] {
        let askedItsVersion = Provenance.Toolchain.isAskedItsVersion(testCommand)
        let identities: [(name: String, was: String?, isNow: String?, identifies: Bool)] = [
            (
                "swiftMutator.executableSHA256",
                recorded.swiftMutator.executableSHA256,
                current.swiftMutator.executableSHA256,
                true
            ),
            (
                "toolchain.testCommandVersion",
                recorded.toolchain.testCommandVersion,
                current.toolchain.testCommandVersion,
                askedItsVersion
            ),
            (
                "toolchain.testExecutableSHA256",
                recorded.toolchain.testExecutableSHA256,
                current.toolchain.testExecutableSHA256,
                !askedItsVersion
            ),
        ]
        var differences = identities.compactMap { identity -> Difference? in
            let unknown = identity.identifies && (identity.was == nil || identity.isNow == nil)
            guard unknown || identity.was != identity.isNow else { return nil }
            return Difference(
                name: identity.name,
                was: identity.was.flatMap { json($0) },
                isNow: identity.isNow.flatMap { json($0) }
            )
        }
        if let environment = difference(
            "toolchain.environment",
            recorded.toolchain.environment,
            current.toolchain.environment
        ) {
            differences.append(environment)
        }
        return differences
    }

    private static func difference<Value: Encodable & Equatable>(
        _ name: String,
        _ was: Value,
        _ isNow: Value
    ) -> Difference? {
        was == isNow ? nil : Difference(name: name, was: json(was), isNow: json(isNow))
    }

    /// `configuration`'s keys and their values, each as sorted-keys JSON.
    private static func values(of configuration: MuterConfiguration) -> [String: String] {
        guard let data = try? JSONEncoder().encode(configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object.compactMapValues { value in
            (try? JSONSerialization.data(withJSONObject: value, options: jsonOptions))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private static func json<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static let jsonOptions: JSONSerialization.WritingOptions = [
        .sortedKeys,
        .fragmentsAllowed,
        .withoutEscapingSlashes,
    ]

    /// What a build or toolchain identity is of, in words, by its name.
    static func subject(of name: String) -> String {
        [
            "swiftMutator.executableSHA256": "SwiftMutator",
            "toolchain.testCommandVersion": "The toolchain",
            "toolchain.testExecutableSHA256": "The test command",
            "toolchain.environment": "The toolchain's environment",
        ][name] ?? name
    }
}

extension ResumeCheck.Current {
    /// What `state` would record in its header: the configuration as loaded, and the mutants asked for.
    init(state: AnyMutationTestState, provenance: Provenance) {
        self.init(
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            provenance: provenance,
            testPlanSHA256: state.testPlan?.sha256,
            since: state.changeSelection,
            shard: state.runOptions.shard,
            sample: state.runOptions.sample,
            mutant: state.selectedMutant?.description
        )
    }
}

extension ResumeCheck.Current {
    /// What `header`'s session recorded, of what a resume compares: the shard the others are merged with.
    init(header: ResultsHeader) {
        self.init(
            configuration: header.configuration,
            operators: header.operators,
            filesToMutate: header.filesToMutate,
            skipCoverage: header.skipCoverage,
            usingTestPlan: header.usingTestPlan,
            provenance: header.provenance,
            testPlanSHA256: header.testPlan?.sha256,
            since: header.since,
            shard: header.shard?.shard,
            sample: header.sample.map { Sample(size: $0.size, seed: $0.seed, seedIsChosen: false) },
            mutant: header.mutant
        )
    }
}

extension ResumeCheck.Difference {
    /// "was 60 and is 120 now", with `absent` for a value that is nil.
    func change(absent: String) -> String {
        "was \(was ?? absent) and is \(isNow ?? absent) now"
    }
}
