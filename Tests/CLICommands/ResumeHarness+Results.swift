@testable import muterCore
import XCTest

extension ResumeHarness {
    /// The run's results file, in `project_muter_logs/<run>/`, which a test expects to be the only one: a resumed
    /// session adds to its file, in whichever log folder it is.
    func onlyResultsFile(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        let files = runs.flatMap { run in
            ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("results") && $0.pathExtension == "jsonl" }
        }
        XCTAssertEqual(files.count, 1, "\(files)", file: file, line: line)
        return try XCTUnwrap(files.first, file: file, line: line)
    }

    /// The log folders in `project_muter_logs/` but `resultsFile`'s own: those of the sessions that resumed its run.
    func resumedSessionsFolders(besides resultsFile: URL) -> [URL] {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let first = resultsFile.deletingLastPathComponent().resolvingSymlinksInPath().path
        return ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.resolvingSymlinksInPath().path != first }
    }

    /// The results file the note in a resumed session's log `folder` names on its first line, symbolic links resolved.
    func notedFile(in folder: URL) throws -> String {
        let note = contents(of: folder.appendingPathComponent("resumed session.txt"))
        let firstLine = try XCTUnwrap(note.components(separatedBy: "\n").first, note)
        return URL(fileURLWithPath: firstLine).resolvingSymlinksInPath().path
    }

    func records(in file: URL) throws -> [[String: Any]] {
        try contents(of: file)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func kinds(in file: URL) throws -> [String?] {
        try records(in: file).map { $0["kind"] as? String }
    }

    /// The worker clones, `project_mutated_worker<n>.noindex`, beside the project.
    func workerClones() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("project_mutated_worker") }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func contents(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// JSON compared as parsed: JSONEncoder promises no key order.
    func parsedJSON(at file: URL) throws -> [String: AnyHashable] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: AnyHashable])
    }

    /// Each mutant's outcome in a JSON report, sorted.
    func outcomes(inJSONReportAt file: URL) throws -> [String] {
        let fileReports = try XCTUnwrap(parsedJSON(at: file)["fileReports"] as? [[String: Any]])
        return fileReports
            .flatMap { ($0["appliedOperators"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["testSuiteOutcome"] as? String }
            .sorted()
    }

    /// The names of the tests each mutant's `killingTests` lists in a JSON report, or nil for a mutant without them:
    /// Checks.swift's mutants first, then Bounds.swift's.
    func killingTestNames(inJSONReportAt file: URL) throws -> [[String]?] {
        let fileReports = try XCTUnwrap(parsedJSON(at: file)["fileReports"] as? [[String: Any]])
        let byFile = Dictionary(uniqueKeysWithValues: fileReports.compactMap { fileReport in
            (fileReport["fileName"] as? String).map { ($0, (fileReport["appliedOperators"] as? [[String: Any]]) ?? []) }
        })
        return (byFile["Checks.swift", default: []] + byFile["Bounds.swift", default: []]).map { appliedOperator in
            ((appliedOperator["killingTests"] as? [String: Any])?["tests"] as? [[String: Any]])
                .map { tests in tests.compactMap { $0["name"] as? String } }
        }
    }
}
