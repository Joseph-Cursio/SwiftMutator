@testable import muterCore
import SwiftParser
import XCTest

/// Swift requires one module's imports of Foundation to agree on whether they state an access
/// level. Measured with swift 6.3.3, in both Swift 5 and 6 language modes: `import Foundation` in
/// one file next to `internal import class Foundation.ProcessInfo` in another fails, and so does the
/// reverse ("ambiguous implicit access level for import of 'Foundation'"); `public import` mixes with
/// either. The injected import therefore copies the module's own level.
final class FoundationImportAccessLevelTests: MuterTestCase {
    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundation-import-\(UUID().uuidString)").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    func test_injectsTheModulesExplicitAccessLevel() {
        write("Sources/App/Foundation.swift", "internal import Foundation\n")
        let file = write("Sources/App/Strings.swift", "func shout(_ text: String) -> String { text }\n")
        write("Sources/Other/Plain.swift", "import Foundation\n")

        XCTAssertEqual(FoundationImportStyle.accessLevel(forFileAt: file), "internal")
    }

    func test_keepsThePlainImportWhenTheModuleUsesPlainOrPublicImports() {
        write("Sources/Plain/A.swift", "import Foundation\n")
        let plain = write("Sources/Plain/B.swift", "func b() {}\n")
        write("Sources/Public/A.swift", "public import Foundation\n")
        let open = write("Sources/Public/B.swift", "func b() {}\n")
        let none = write("Sources/NoFoundation/B.swift", "func b() {}\n")

        XCTAssertNil(FoundationImportStyle.accessLevel(forFileAt: plain))
        XCTAssertNil(FoundationImportStyle.accessLevel(forFileAt: open))
        XCTAssertNil(FoundationImportStyle.accessLevel(forFileAt: none))
    }

    // Documentation catalogs hold code samples, and a sample's `import Foundation` is not an import.
    func test_ignoresImportsOutsideSwiftSources() {
        write("Sources/App/Foundation.swift", "internal import Foundation\n")
        write("Sources/App/App.docc/GettingStarted.md", "```swift\nimport Foundation\n```\n")
        let file = write("Sources/App/Strings.swift", "func b() {}\n")

        XCTAssertEqual(FoundationImportStyle.accessLevel(forFileAt: file), "internal")
    }

    func test_rewriterEmitsTheImportWithItsAccessLevel() throws {
        let code = try sourceCode("func b() {}\n")

        let plain = AddImportRewriter().visit(code).description
        let scoped = AddImportRewriter(accessLevel: "internal").visit(code).description

        XCTAssertTrue(plain.contains("import class Foundation.ProcessInfo"), plain)
        XCTAssertFalse(plain.contains("internal import"), plain)
        XCTAssertTrue(scoped.contains("internal import class Foundation.ProcessInfo"), scoped)
        XCTAssertFalse(Parser.parse(source: scoped).hasError, scoped)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
