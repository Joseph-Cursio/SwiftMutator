@testable import muterCore

extension ResumeCheckTests {
    /// The fixture's configuration: `swift test`.
    var swift: MuterConfiguration {
        MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
    }

    /// The project tree every recorded header holds unless a test gives its own.
    static let tree = ProjectTree(
        listedBy: .git,
        files: ["Sources/Sum.swift": "ab12"],
        excluded: [],
        treeSHA256: "cd34"
    )

    func current(
        configuration: MuterConfiguration? = nil,
        operators: [String] = ["RelationalOperatorReplacement"],
        filesToMutate: [String] = [],
        skipCoverage: Bool = true,
        usingTestPlan: Bool = false,
        testPlanSHA256: String? = nil,
        provenance: Provenance = .fixture,
        since: ChangeSelection? = nil,
        shard: Shard? = nil,
        sample: Sample? = nil,
        mutant: String? = nil
    ) -> ResumeCheck.Current {
        ResumeCheck.Current(
            configuration: configuration ?? swift,
            operators: operators,
            filesToMutate: filesToMutate,
            skipCoverage: skipCoverage,
            usingTestPlan: usingTestPlan,
            provenance: provenance,
            testPlanSHA256: testPlanSHA256,
            since: since,
            shard: shard,
            sample: sample,
            mutant: mutant
        )
    }

    /// The header a session of `current` wrote.
    func header(
        of current: ResumeCheck.Current,
        project: ProjectTree? = ResumeCheckTests.tree
    ) -> ResultsHeader {
        ResultsHeader.make(
            project: project,
            provenance: current.provenance,
            configuration: current.configuration,
            operators: current.operators,
            filesToMutate: current.filesToMutate,
            skipCoverage: current.skipCoverage,
            usingTestPlan: current.usingTestPlan,
            since: current.since,
            shard: current.shard.map { ShardSelection.make(index: $0.index, count: $0.count) },
            sample: current.sample.map {
                SampleSelection(size: $0.size, seed: $0.seed, mutantsSampledFrom: 2_463, mutantsSampled: $0.size)
            },
            testPlan: current.testPlanSHA256.map {
                TestPlanRecord(
                    path: "/project/muter-mappings.json",
                    sha256: $0,
                    formatVersion: TestPlanCoding.formatVersion,
                    swiftMutatorVersion: "16"
                )
            },
            mutant: current.mutant
        )
    }

    /// `current` checked against `recorded`, by default the header of a session with the fixture's run.
    func check(
        _ current: ResumeCheck.Current,
        recorded: ResultsHeader? = nil,
        forcing: Bool = false,
        for purpose: ResumeCheck.Purpose = .resume,
        longestLimit: Double? = nil
    ) -> ResumeCheck.Verdict {
        ResumeCheck.compare(
            recorded ?? header(of: self.current()),
            with: current,
            forcing: forcing,
            for: purpose,
            longestLimit: longestLimit
        )
    }

    func provenance(
        executableSHA256: String? = Provenance.fixture.swiftMutator.executableSHA256,
        testCommandVersion: String? = Provenance.fixture.toolchain.testCommandVersion,
        testExecutableSHA256: String? = nil,
        environment: [String: String] = Provenance.fixture.toolchain.environment
    ) -> Provenance {
        let fixture = Provenance.fixture
        return Provenance(
            swiftMutator: .init(
                version: fixture.swiftMutator.version,
                executablePath: fixture.swiftMutator.executablePath,
                executableSHA256: executableSHA256
            ),
            toolchain: .init(
                testCommandVersion: testCommandVersion,
                testExecutableSHA256: testExecutableSHA256,
                environment: environment
            ),
            processIdentifier: fixture.processIdentifier,
            host: fixture.host,
            arguments: fixture.arguments
        )
    }

    func configurationKey(_ refusal: ResumeRefusal) -> String? {
        guard case let .configurationChanged(difference) = refusal else { return nil }
        return difference.name
    }
}
