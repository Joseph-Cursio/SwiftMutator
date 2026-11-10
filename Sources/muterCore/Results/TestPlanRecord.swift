/// The test plan a session tested: the path it was read from, absolute, the SHA-256 of its bytes, and which format and
/// SwiftMutator it was written in. A plan made again, or edited, has another SHA-256.
struct TestPlanRecord: Codable, Equatable {
    let path: String
    let sha256: String
    let formatVersion: Int
    /// Absent for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
}
