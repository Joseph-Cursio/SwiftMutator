@testable import muterCore
import XCTest

final class SourceFileExcludesTests: XCTestCase {
    func test_theDefaults_leaveOutTestsAndWhatServesThem() {
        let isExcluded = SourceFileExcludes.matcher([])
        for path in [
            "Tests/AppTests/ModelTests.swift", "Sources/App/ModelTests.swift", "Sources/App/ModelSpec.swift",
            "Sources/Mocks/Network.swift", "Sources/App/Stubs/Clock.swift", "Sources/Fakes/Store.swift",
            "Sources/TestHelpers/Wait.swift", "Sources/TestSupport/Fixtures.swift", "Sources/App/NetworkMock.swift",
            "Snippets/Intro.swift", "DerivedData/App/Build/Gen.swift", "Package.swift", "Package@swift-6.0.swift",
            ".build/checkouts/Dep/Dep.swift", "Pods/Dep/Dep.swift",
        ] {
            XCTAssertTrue(isExcluded(path), path)
        }
        for path in ["Sources/App/Model.swift", "Sources/Mocking/Model.swift", "Sources/App/MockingBird.swift"] {
            XCTAssertFalse(isExcluded(path), path)
        }
    }

    func test_anEntryThatStartsWithABang_keepsWhatItMatches_overTheDefaultsAndOtherEntries() {
        let isExcluded = SourceFileExcludes.matcher(["/Generated/", "!/Stubs/", "!Sources/App/Generated/Keep.swift"])
        XCTAssertFalse(isExcluded("Sources/Stubs/Clock.swift"))
        XCTAssertFalse(isExcluded("Sources/App/Generated/Keep.swift"))
        XCTAssertTrue(isExcluded("Sources/App/Generated/API.swift"))
        XCTAssertTrue(isExcluded("Sources/Mocks/Network.swift"))

        let globs = SourceFileExcludes.matcher(["!Sources/**/Mocks/*.swift"])
        XCTAssertFalse(globs("Sources/App/Mocks/Network.swift"))
        XCTAssertTrue(globs("Tests/Mocks/Network.swift"))
    }

    // A mutant in the project's manifest never switches on, and a build folder isn't the project's code.
    func test_anEntryThatStartsWithABang_cantKeepTheManifestOrABuildFolder() {
        let isExcluded = SourceFileExcludes.matcher(["!Package.swift", "!/.build/", "!**", "!Package@swift-"])
        XCTAssertTrue(isExcluded("Package.swift"))
        XCTAssertTrue(isExcluded("Package@swift-6.0.swift"))
        XCTAssertTrue(isExcluded(".build/checkouts/Dep/Dep.swift"))
        XCTAssertTrue(isExcluded("Sources/.swiftpm/Gen.swift"))
        XCTAssertFalse(isExcluded("Tests/AppTests/ModelTests.swift"))
    }

    // Most likely a local package's manifest, which the defaults leave out, but it may be a model.
    func test_aDeeperFileNamedPackage_isLeftOut_butCanBeKept() {
        XCTAssertTrue(SourceFileExcludes.matcher([])("Sources/Registry/Package.swift"))
        XCTAssertTrue(SourceFileExcludes.matcher([])("Packages/Core/Package@swift-6.0.swift"))
        XCTAssertFalse(SourceFileExcludes.matcher(["!Sources/Registry/"])("Sources/Registry/Package.swift"))
        XCTAssertFalse(SourceFileExcludes.isAlwaysExcluded("Sources/Registry/Package.swift"))
        XCTAssertTrue(SourceFileExcludes.isAlwaysExcluded("Package.swift"))
    }

    // `!` alone, or an empty entry, used to match every path.
    func test_anEmptyEntry_matchesNothing() {
        XCTAssertFalse(SourceFileExcludes.matcher([""])("Sources/App/Model.swift"))
        XCTAssertTrue(SourceFileExcludes.matcher(["!"])("Tests/AppTests/ModelTests.swift"))
    }
}
