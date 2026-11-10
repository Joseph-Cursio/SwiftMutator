import Foundation

/// What a test plan's mutants were chosen by: the operators and `--files-to-mutate`, as `mutate-without-running` was
/// given them. A run that tests the plan records them in its results file, as a run that discovers its own mutants
/// records its options.
struct TestPlanScope: Equatable, Sendable {
    /// Sorted by name, as the plan writes them, so the same choice is the same scope whatever order named it.
    let operators: MutationOperatorList
    /// Empty when the mutants were chosen from every file.
    let filesToMutate: [String]

    init(operators: MutationOperatorList, filesToMutate: [String]) {
        self.operators = operators.sorted { $0.rawValue < $1.rawValue }
        self.filesToMutate = filesToMutate
    }
}

/// The test plan a run tests: where it was read from, the SHA-256 of its bytes, which format and SwiftMutator it was
/// written in, what its mutants were chosen by, the project's files it was made from, and the files with mutants it
/// left in the copy.
struct LoadedTestPlan: Equatable, Sendable {
    let path: String
    let sha256: String
    let formatVersion: Int
    /// Nil for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
    /// Nil for a plan in format 0, which doesn't say; the run then records the operators and files it was given.
    let scope: TestPlanScope?
    /// Nil for a plan in format 0, which doesn't record them; the project then isn't checked against the plan.
    let sources: ProjectTree?
    /// The SHA-256 of each file with mutants as the plan left it in the copy, by its path relative to the copy, which
    /// tells a fix by hand; nil for a plan in format 0, which doesn't record them.
    let mutatedFiles: [String: String]?
    /// The SHA-256 of what each file with mutants that is a symbolic link in the project held when the plan was made,
    /// by its path relative to the project; nil when none is, and for a plan that doesn't record them.
    let linkedFiles: [String: String]?
    /// The paths of all the plan's files with mutants, relative to the copy and so to the project, which `--mutant`
    /// doesn't narrow as it narrows the run's mappings. A file outside the copy is left out.
    let mutatedPaths: Set<String>
}

/// The test plan `mutate-without-running` wrote, as it reports it: where the plan is, the copy it names, and what it
/// holds.
struct TestPlanCreated: Equatable {
    let path: String
    /// The copy, as the plan names it: relative to the project folder, as `../Foo_mutated.noindex`.
    let mutatedProject: String
    let mutants: Int
    let files: Int
    /// The operators the mutants were chosen by, by name and sorted; nil when every operator was.
    let operators: [String]?
}

/// A test plan as the steps use it: its paths absolute, wherever the plan file holds them relative to the project
/// (`TestPlanFile`).
struct MuterTestPlan: Equatable {
    /// The format the plan was read in, or the one `TestPlanCoding` writes for a plan being made.
    let formatVersion: Int
    /// The SwiftMutator that made the plan; nil for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
    /// The copy of the project the plan's mutants are in, with no `..` in its path.
    let mutatedProjectURL: URL
    /// `.null` when coverage wasn't gathered.
    let projectCoverage: Coverage
    /// What the mutants were chosen by; nil for a plan in format 0, which doesn't say.
    let scope: TestPlanScope?
    /// The project's own files as they were when the plan was made; nil for a plan in format 0, which doesn't record
    /// them.
    let sources: ProjectTree?
    /// The SHA-256 of each file with mutants as the plan left it in the copy, by its path relative to the copy; nil
    /// for a plan in format 0.
    let mutatedFiles: [String: String]?
    /// The SHA-256 of what each file with mutants that is a symbolic link in the project held when the plan was made,
    /// by its path relative to the project: `sources` records only where such a link points. Nil when no such file is
    /// a link, and for a plan that doesn't record them.
    let linkedFiles: [String: String]?
    let mappings: [SchemataMutationMapping]
    /// The mutants of code no test ran, which the plan makes none of (`UncoveredMutant`), keyed by their paths relative
    /// to the copy, and so to the project, sorted by key, so that a run of the plan compares them with `--baseline`'s
    /// file, and records them in its results file, as a run that discovers its own mutants does; empty when there are
    /// none, as with `--skip-coverage`. nil for a plan that doesn't record them, as an older SwiftMutator's.
    let mutantsNotCovered: [UncoveredMutant]?

    init(
        formatVersion: Int = TestPlanCoding.formatVersion,
        swiftMutatorVersion: String? = version,
        mutatedProjectURL: URL,
        projectCoverage: Coverage,
        scope: TestPlanScope?,
        sources: ProjectTree? = nil,
        mutatedFiles: [String: String]? = nil,
        linkedFiles: [String: String]? = nil,
        mappings: [SchemataMutationMapping],
        mutantsNotCovered: [UncoveredMutant]? = nil
    ) {
        self.formatVersion = formatVersion
        self.swiftMutatorVersion = swiftMutatorVersion
        self.mutatedProjectURL = mutatedProjectURL
        self.projectCoverage = projectCoverage
        self.scope = scope
        self.sources = sources
        self.mutatedFiles = mutatedFiles
        self.linkedFiles = linkedFiles
        self.mappings = mappings
        self.mutantsNotCovered = mutantsNotCovered
    }
}
