@testable import muterCore
import XCTest

final class CanonicalPathTests: XCTestCase {
    func test_resolvesSymbolicLinks() throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        FileManager.default.createFile(atPath: "\(directory)/file.swift", contents: Data())

        let canonicalPath = "\(link)/file.swift".canonicalPath

        XCTAssertEqual(canonicalPath, "\(directory)/file.swift".canonicalPath)
        XCTAssertTrue(canonicalPath.hasSuffix("/directory/file.swift"), canonicalPath)
    }

    func test_leavesAPathThatDoesNotExistUnchanged() throws {
        let (_, link) = try makeDirectoryWithSymbolicLink()

        XCTAssertEqual("\(link)/missing.swift".canonicalPath, "\(link)/missing.swift")
    }

    func test_leavesARelativePathUnchanged() throws {
        let (_, link) = try makeDirectoryWithSymbolicLink()
        FileManager.default.createFile(atPath: "\(link)/file.swift", contents: Data())

        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(link)
        defer { FileManager.default.changeCurrentDirectoryPath(currentDirectoryPath) }

        XCTAssertEqual("file.swift".canonicalPath, "file.swift")
    }
}
