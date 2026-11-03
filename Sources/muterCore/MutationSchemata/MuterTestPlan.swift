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
    let mappings: [SchemataMutationMapping]

    init(
        formatVersion: Int = TestPlanCoding.formatVersion,
        swiftMutatorVersion: String? = version,
        mutatedProjectURL: URL,
        projectCoverage: Coverage,
        mappings: [SchemataMutationMapping]
    ) {
        self.formatVersion = formatVersion
        self.swiftMutatorVersion = swiftMutatorVersion
        self.mutatedProjectURL = mutatedProjectURL
        self.projectCoverage = projectCoverage
        self.mappings = mappings
    }
}

/// The test plan a run tests: where it was read from, the SHA-256 of its bytes, and which format and SwiftMutator it
/// was written in.
struct LoadedTestPlan: Equatable, Sendable {
    let path: String
    let sha256: String
    let formatVersion: Int
    /// Nil for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
}
