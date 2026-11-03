import Foundation

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
    let mappings: [SchemataMutationMapping]

    init(
        formatVersion: Int = TestPlanCoding.formatVersion,
        swiftMutatorVersion: String? = version,
        mutatedProjectURL: URL,
        projectCoverage: Coverage,
        scope: TestPlanScope?,
        mappings: [SchemataMutationMapping]
    ) {
        self.formatVersion = formatVersion
        self.swiftMutatorVersion = swiftMutatorVersion
        self.mutatedProjectURL = mutatedProjectURL
        self.projectCoverage = projectCoverage
        self.scope = scope
        self.mappings = mappings
    }
}

/// What a test plan's mutants were chosen by: `--operators` and `--files-to-mutate`, as `mutate-without-running` was
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
/// written in, and what its mutants were chosen by.
struct LoadedTestPlan: Equatable, Sendable {
    let path: String
    let sha256: String
    let formatVersion: Int
    /// Nil for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
    /// Nil for a plan in format 0, which doesn't say; the run then records the operators and files it was given.
    let scope: TestPlanScope?
}

/// The test plan `mutate-without-running` wrote, as it reports it: where the plan is, the copy it names, and what it
/// holds.
struct TestPlanCreated: Equatable {
    let path: String
    /// The copy, as the plan names it: relative to the project folder, as `../Foo_mutated`.
    let mutatedProject: String
    let mutants: Int
    let files: Int
    /// The operators the mutants were chosen by, by name and sorted; nil when every operator was.
    let operators: [String]?
}
