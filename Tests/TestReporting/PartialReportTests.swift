@testable import muterCore
import XCTest

final class PartialReportTests: XCTestCase {
    func test_isBesideTheRequestedReport_keepingItsExtension() {
        XCTAssertEqual(PartialReport.path(besides: "/out/report.txt"), "/out/report.partial.txt")
        XCTAssertEqual(PartialReport.path(besides: "/out/report.json"), "/out/report.partial.json")
    }

    func test_aRequestedReportWithoutAnExtension_getsAPartialOneWithout() {
        XCTAssertEqual(PartialReport.path(besides: "/out/report"), "/out/report.partial")
    }

    func test_aDotInAFolderName_isNotTheReportsExtension() {
        XCTAssertEqual(PartialReport.path(besides: "/out/dir.v2/report"), "/out/dir.v2/report.partial")
    }

    // Without one, what was tested is in the summary and the results file.
    func test_withoutARequestedReport_thereIsNoPartialOne() {
        XCTAssertNil(PartialReport.path(besides: nil))
        XCTAssertNil(PartialReport.path(besides: ""))
    }
}
