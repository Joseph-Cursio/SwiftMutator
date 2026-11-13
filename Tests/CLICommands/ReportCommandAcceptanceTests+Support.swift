#if os(Linux)
import Glibc
#endif
import XCTest

extension ReportCommandAcceptanceTests {
    /// Kills a SwiftMutator that is still running, and the process group Foundation.Process started it in, which holds
    /// it alone.
    func stop(_ process: Foundation.Process) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        #if os(Linux)
        Glibc.kill(-pid, SIGKILL)
        Glibc.kill(pid, SIGKILL)
        #else
        Darwin.kill(-pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
        #endif
        process.waitUntilExit()
    }

    func contents(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
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

    /// The names of the tests each mutant's `killingTests` lists in a JSON report, by file, or nil for a mutant without
    /// them.
    func killingTestNames(inJSONReportAt file: URL) throws -> [String: [[String]?]] {
        let fileReports = try XCTUnwrap(parsedJSON(at: file)["fileReports"] as? [[String: Any]])
        var names: [String: [[String]?]] = [:]
        for fileReport in fileReports {
            let fileName = try XCTUnwrap(fileReport["fileName"] as? String)
            names[fileName] = ((fileReport["appliedOperators"] as? [[String: Any]]) ?? []).map { appliedOperator in
                ((appliedOperator["killingTests"] as? [String: Any])?["tests"] as? [[String: Any]])
                    .map { tests in tests.compactMap { $0["name"] as? String } }
            }
        }
        return names
    }

    /// The HTML report with its footer, the time it was made, left empty.
    func withoutFooter(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<footer class="footer">[^<]*</footer>"#,
            with: #"<footer class="footer"></footer>"#,
            options: .regularExpression
        )
    }

    /// The Xcode format's warnings in `output`, in the order printed, without any escape codes around them, such as a
    /// progress bar's on a terminal.
    func warnings(in output: String) -> [String] {
        let pattern = #"/[^\u001B\n]*: warning: Your test suite did not kill this mutant: [^\u001B\n]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("The warning pattern doesn't compile")
            return []
        }
        return expression
            .matches(in: output, range: NSRange(output.startIndex..., in: output))
            .compactMap { Range($0.range, in: output).map { String(output[$0]) } }
    }
}
