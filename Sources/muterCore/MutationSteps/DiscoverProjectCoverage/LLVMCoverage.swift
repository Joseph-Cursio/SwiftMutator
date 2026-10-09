import Foundation

struct Region: Equatable {
    let lineStart: Int
    let columnStart: Int
    let lineEnd: Int
    let columnEnd: Int
    let executionCount: Int
    let kind: Kind

    /// llvm-cov's region kinds, from the eighth element of each exported region.
    enum Kind: Int {
        case code = 0
        case expansion = 1
        case skipped = 2
        case gap = 3
        case branch = 4
        case other = -1
    }

    init(
        lineStart: Int,
        columnStart: Int,
        lineEnd: Int,
        columnEnd: Int,
        executionCount: Int = 0,
        kind: Kind = .code
    ) {
        self.lineStart = lineStart
        self.columnStart = columnStart
        self.lineEnd = lineEnd
        self.columnEnd = columnEnd
        self.executionCount = executionCount
        self.kind = kind
    }
}

extension Region: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let data = try container.decode([Int].self)

        lineStart = data[safe: 0] ?? 0
        columnStart = data[safe: 1] ?? 0
        lineEnd = data[safe: 2] ?? 0
        columnEnd = data[safe: 3] ?? 0
        executionCount = data[safe: 4] ?? 0
        // Exports without the field predate region kinds; treat them as code, as before.
        kind = data[safe: 7].map { Kind(rawValue: $0) ?? .other } ?? .code
    }

    /// Whether `other` lies entirely inside this region. Positions compare as (line, column) pairs,
    /// so a region that ends on a line before `other` starts never contains it, whatever the columns.
    func contains(_ other: Region) -> Bool {
        (lineStart, columnStart) <= (other.lineStart, other.columnStart)
            && (other.lineEnd, other.columnEnd) <= (lineEnd, columnEnd)
    }
}

struct Function: Decodable {
    let filenames: [String]
    let regions: [Region]
}

struct LLVMCoverage: Decodable {
    let data: [Data]

    struct Data: Decodable {
        let functions: [Function]
        /// Each source file's summary.
        let files: [File]

        init(functions: [Function], files: [File] = []) {
            self.functions = functions
            self.files = files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            functions = try container.decode([Function].self, forKey: .functions)
            files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case functions
            case files
        }
    }

    struct File: Decodable {
        let filename: String
        let summary: Summary
    }

    struct Summary: Decodable {
        let lines: Lines
    }

    /// How many lines of a file the tests could run, how many of them they ran, and that as a percentage.
    struct Lines: Decodable {
        let count: Int
        let covered: Int
        let percent: Double
    }
}
