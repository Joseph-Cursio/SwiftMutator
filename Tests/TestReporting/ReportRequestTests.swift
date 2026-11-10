@testable import muterCore
import XCTest

/// `format:path`, as `--report` and `reports:` give it (`ReportRequest`).
final class ReportRequestTests: MuterTestCase {
    func test_parse_splitsAtTheFirstColonOnly() {
        XCTAssertEqual(
            try ReportRequest.parse("markdown:summary.md").get(),
            ReportRequest(format: .markdown, path: "summary.md")
        )
        XCTAssertEqual(
            try ReportRequest.parse("html:out/a:b.html").get(),
            ReportRequest(format: .html, path: "out/a:b.html")
        )
        for format in ReportFormat.allCases where format != .xcode {
            XCTAssertEqual(try ReportRequest.parse("\(format.rawValue):r").get().format, format)
        }
    }

    // The Xcode format's warnings are printed as the run goes, which only -f's report is.
    func test_parse_refusesWhatIsntARequest() {
        let refused = [
            ("summary.md", "name the format and then the path"),
            (":summary.md", "name the format and then the path"),
            (
                "pdf:summary.pdf",
                "start with one of the formats plain, json, html, markdown, stryker, sarif, as format:path"
            ),
            ("Markdown:summary.md", "start with one of the formats"),
            ("markdown:", "give a path after the format"),
            ("xcode:report.txt", "save the Xcode format with -f xcode"),
        ]
        for (text, problem) in refused {
            guard case let .failure(found) = ReportRequest.parse(text) else {
                XCTFail(text)
                return
            }
            XCTAssertTrue(found.description.hasPrefix(problem), "\(text): \(found)")
            XCTAssertTrue(found.description.hasSuffix("such as markdown:summary.md"), "\(text): \(found)")
        }
    }

    // One string, as YAML and the results header write it.
    func test_isCodedAsItsText() throws {
        let request = ReportRequest(format: .json, path: "/out/a:b.json")

        let written = String(lossyUTF8: try JSONEncoder().encode([request]))
        XCTAssertEqual(written, #"["json:\/out\/a:b.json"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ReportRequest].self, from: JSONEncoder().encode([request])), [request])
        XCTAssertThrowsError(try JSONDecoder().decode([ReportRequest].self, from: Data(#"["xcode:r.txt"]"#.utf8)))
    }

    // As -o's: against the current folder, or the project's for a run; an absolute path stays.
    func test_resolved_keepsAnAbsolutePath_andResolvesARelativeOne() {
        fileManager.currentDirectoryPathToReturn = "/project"

        XCTAssertEqual(
            ReportRequest(format: .markdown, path: "out/summary.md").resolved.path,
            "/project/out/summary.md"
        )
        XCTAssertEqual(ReportRequest(format: .markdown, path: "/tmp/summary.md").resolved.path, "/tmp/summary.md")
        XCTAssertEqual(
            ReportRequest(format: .html, path: "r.html").resolved(in: "/other"),
            ReportRequest(format: .html, path: "/other/r.html")
        )
    }

    func test_clash_findsTwoAtOnePath_orOneAtAnothersPartialReport() {
        XCTAssertNil(ReportRequest.clash(
            among: [("-o /r.txt", "/r.txt"), ("--report markdown:/r.md", "/r.md")], ofARun: true
        ))
        for isARun in [true, false] {
            XCTAssertEqual(
                ReportRequest.clash(among: [("a", "/out/r.md"), ("b", "/out/sub/../r.md")], ofARun: isARun),
                "a and b would save to the same file"
            )
        }
        XCTAssertEqual(
            ReportRequest.clash(among: [("a", "/out/r"), ("b", "/out/r.partial")], ofARun: true),
            "b would save where a's partial report goes when a run stops"
        )
        // `report` writes no partial report.
        XCTAssertNil(ReportRequest.clash(among: [("a", "/out/r"), ("b", "/out/r.partial")], ofARun: false))
    }

    // A shell expands `~` only at the start of a word, never after `markdown:`, and YAML never does.
    func test_aLeadingTilde_isTheHomeFolder() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            ReportRequest(format: .markdown, path: "~/summary.md").resolved(in: "/project"),
            ReportRequest(format: .markdown, path: home + "/summary.md")
        )
        XCTAssertEqual(
            ReportRequest(format: .markdown, path: "~").resolved(in: "/project").path,
            home
        )
        XCTAssertEqual(
            ReportRequest(format: .markdown, path: "a/~/summary.md").resolved(in: "/project").path,
            "/project/a/~/summary.md"
        )
    }
}
