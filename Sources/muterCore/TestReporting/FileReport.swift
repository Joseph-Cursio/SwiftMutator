import Foundation

/// One file's part of a report: its mutants, and their score.
struct FileReport: Codable, Comparable {
    let fileName: FileName
    let path: FilePath
    /// Its path relative to the project, as every report shows it but the Xcode format; for a file outside the
    /// project, its absolute path. The JSON's `path`.
    let relativePath: String
    let mutationScore: Int
    var appliedOperators: [AppliedMutationOperator]

    enum CodingKeys: String, CodingKey {
        case fileName
        // The JSON's `path` is relative to the project; the absolute one isn't in it.
        case relativePath = "path"
        case mutationScore
        case appliedOperators
    }

    init(
        fileName: FileName,
        path: FilePath,
        mutationScore: Int,
        appliedOperators: [AppliedMutationOperator],
        relativePath: String? = nil
    ) {
        self.fileName = fileName
        self.path = path
        self.relativePath = relativePath ?? fileName
        self.mutationScore = mutationScore
        self.appliedOperators = appliedOperators
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decode(FileName.self, forKey: .fileName)
        mutationScore = try container.decode(Int.self, forKey: .mutationScore)
        appliedOperators = try container.decode([AppliedMutationOperator].self, forKey: .appliedOperators)
        path = ""
        // A report written before reports had it has the name alone.
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? fileName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(mutationScore, forKey: .mutationScore)
        try container.encode(appliedOperators, forKey: .appliedOperators)
    }

    /// By path, as the run tests them.
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.relativePath < rhs.relativePath
    }
}
