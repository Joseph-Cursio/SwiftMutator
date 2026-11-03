import Foundation

struct MuterTestPlan: Equatable, Codable {
    let mutatedProjectPath: String
    let projectCoverage: Int
    let mappings: [SchemataMutationMapping]
}

/// How a test plan is written. It is a file people read, diff and commit, so it is pretty-printed and ends in a
/// newline; its keys are sorted, so a plan of the same mutants is the same bytes; and its slashes are unescaped, so
/// paths read as paths. Any JSON decoder reads it, as it reads a plan written on one line.
enum TestPlanCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The plan's text, as `CreateMuterTestPlan` writes it.
    static func encode(_ plan: MuterTestPlan) throws -> String {
        try String(decoding: encoder.encode(plan), as: UTF8.self) + "\n"
    }
}
