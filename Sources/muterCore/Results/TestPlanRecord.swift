/// The test plan a session tested: the path it was read from, absolute, the SHA-256 of its bytes, and which format and
/// SwiftMutator it was written in. A plan made again, or edited, has another SHA-256.
struct TestPlanRecord: Codable, Equatable {
    let path: String // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    let sha256: String
    let formatVersion: Int // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// Absent for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String? // swiftlint:disable:this unused_declaration - results file key; Codable writes it
}
