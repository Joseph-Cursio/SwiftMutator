import Foundation

/// A report in the mutation-testing-elements schema, version 2, which Stryker's dashboard and report viewer read:
/// https://github.com/stryker-mutator/mutation-testing-elements/tree/master/packages/report-schema. Only the parts
/// SwiftMutator has something to put in; every other one is optional and left out.
struct StrykerReport: Codable, Equatable {
    let schemaVersion: String
    let thresholds: Thresholds
    /// The project's absolute path; nil, and left out, when not known.
    let projectRoot: String?
    let framework: Framework
    /// By the file's path relative to the project; a file outside it keeps its absolute path.
    let files: [String: File]
    /// The tests that killed some mutant, under the one key `""`, as a results line records no test's file. nil, and
    /// left out, when no kill named a test.
    let testFiles: [String: TestFile]?

    /// Stryker's own defaults: a score of 80 or more is good, and one under 60 is poor.
    struct Thresholds: Codable, Equatable {
        let high: Int
        let low: Int
    }

    /// The tool that made the report, without its dependencies.
    struct Framework: Codable, Equatable {
        let name: String
        let version: String
    }

    struct File: Codable, Equatable {
        let language: String
        /// The original file's text as it is now, which the viewer shows each mutant in; "" when it can't be read.
        let source: String
        let mutants: [Mutant]
    }

    struct Mutant: Codable, Equatable {
        /// The mutant's key, as `--mutant` takes it, so the same mutant has the same id in every run's report.
        let id: String
        let mutatorName: String
        /// What the mutant puts in place of the code at `location`.
        let replacement: String
        let description: String
        let location: Location
        let status: Status
        let statusReason: String?
        /// The ids of the tests recorded failing, in `testFiles`; nil, and left out, when none was.
        let killedBy: [String]?
        /// How long its run took, in milliseconds; nil, and left out, when not known.
        let duration: Int?
    }

    struct Location: Codable, Equatable {
        let start: Position
        /// Just past the code the mutant changes.
        let end: Position
    }

    /// From 1. The column counts UTF-16 code units, as the viewer's JavaScript does.
    struct Position: Codable, Equatable {
        let line: Int
        let column: Int
    }

    enum Status: String, Codable, Equatable {
        case killed = "Killed"
        case survived = "Survived"
        case noCoverage = "NoCoverage"
        case compileError = "CompileError"
        case timeout = "Timeout"
    }

    struct TestFile: Codable, Equatable {
        let tests: [Test]
    }

    /// A test by its name, which is also its id: the name is all a results line records of it.
    struct Test: Codable, Equatable {
        let id: String
        let name: String
    }
}

extension StrykerReport.Location {
    init(_ span: SourceSpan) {
        start = StrykerReport.Position(line: span.start.line, column: span.start.column)
        end = StrykerReport.Position(line: span.end.line, column: span.end.column)
    }
}
