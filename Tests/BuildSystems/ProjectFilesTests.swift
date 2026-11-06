import Foundation
@testable import muterCore
import XCTest

final class ProjectFilesTests: MuterTestCase {
    private var project: URL!
    private var fixture: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        project = try URL(fileURLWithPath: makeTemporaryDirectory())
        fixture = project.appendingPathComponent("Tests/fixture.txt")
        try FileManager.default.createDirectory(
            at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "one".write(to: fixture, atomically: false, encoding: .utf8)
    }

    /// The change `change` makes, between two readings far enough apart for a file's time to show it.
    private func firstChange(after change: () throws -> Void) throws -> String? {
        let before = try XCTUnwrap(ProjectFiles.read(in: project))
        Thread.sleep(forTimeInterval: 0.01)
        try change()
        return before.firstChange(in: try XCTUnwrap(ProjectFiles.read(in: project)))
    }

    func test_readingWithoutChanging_showsNoChange() throws {
        XCTAssertNil(try firstChange {
            _ = try String(contentsOf: fixture, encoding: .utf8)
            _ = try FileManager.default.contentsOfDirectory(atPath: project.path)
        })
    }

    func test_aNewFile_shows() throws {
        let change = try firstChange {
            try "new".write(to: project.appendingPathComponent("Tests/new.txt"), atomically: false, encoding: .utf8)
        }

        XCTAssertEqual(change, "Tests", "its folder, which sorts before it")
    }

    // The same size, so only the time shows it.
    func test_aFileRewrittenInPlace_shows() throws {
        XCTAssertEqual(
            try firstChange { try "two".write(to: fixture, atomically: false, encoding: .utf8) },
            "Tests/fixture.txt"
        )
    }

    // swift-mutation-testing#187's false kills came from a fixture next to its test, which comparing only what the
    // project holds before and after wouldn't see once the test removes it.
    func test_aFileWrittenAndRemoved_showsInItsFolder() throws {
        let change = try firstChange {
            let gone = project.appendingPathComponent("Tests/gone.txt")
            try "gone".write(to: gone, atomically: false, encoding: .utf8)
            try FileManager.default.removeItem(at: gone)
        }

        XCTAssertEqual(change, "Tests")
    }

    func test_aNewFileAtTheTop_showsByName_ratherThanAsTheProjectsFolder() throws {
        let change = try firstChange {
            try "new".write(to: project.appendingPathComponent("new.txt"), atomically: false, encoding: .utf8)
        }

        XCTAssertEqual(change, "new.txt")
    }

    func test_aFileWrittenAndRemovedAtTheTop_showsAsTheProjectsFolder() throws {
        let change = try firstChange {
            let gone = project.appendingPathComponent("gone.txt")
            try "gone".write(to: gone, atomically: false, encoding: .utf8)
            try FileManager.default.removeItem(at: gone)
        }

        XCTAssertEqual(change, "")
    }

    func test_whatsInsideALinkedFolder_isntFollowed() throws {
        let outside = try URL(fileURLWithPath: makeTemporaryDirectory())
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("linked"), withDestinationURL: outside
        )

        XCTAssertNil(try firstChange {
            try "x".write(to: outside.appendingPathComponent("x.txt"), atomically: false, encoding: .utf8)
        })
    }
}
