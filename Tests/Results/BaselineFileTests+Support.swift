@testable import muterCore
import XCTest

extension BaselineFileTests {
    var path: String { "\(directory)/\(BaselineFile.fileName)" }

    func key(_ path: String, _ line: Int, _ column: Int = 9, occurrence: Int = 0) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: .ror, line: line, column: column, occurrence: occurrence)
    }

    func file(_ survivors: [BaselineSurvivor], at path: String? = nil) -> BaselineFile {
        BaselineFile(
            path: path ?? self.path,
            swiftMutator: "0.1.0",
            score: .init(killed: 812, scored: 1_003),
            scope: scope,
            survivors: survivors
        )
    }

    func load(_ text: String) throws -> BaselineFile {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return try BaselineFile.load(at: path, using: FileManager.default)
    }

    func assertRefused(_ text: String, saying words: String, line: UInt = #line) {
        XCTAssertThrowsError(try load(text), line: line) { error in
            XCTAssertTrue(error is BaselineRefused, "\(error)", line: line)
            XCTAssertTrue("\(error)".contains(words), "\(error)", line: line)
            XCTAssertTrue("\(error)".contains(path), "names the file: \(error)", line: line)
        }
    }

    var minimal: String {
        """
        formatVersion: 1
        swiftMutator: 0.1.0
        score:
          killed: 1
          scored: 2
        scope:
          operators: [SwapTernary]
          skipCoverage: false
          configuration:
            arguments: [test]
            coverageThreshold: 0
            exclude: []
            excludeCalls: []
        survivors: []
        """
    }
}
