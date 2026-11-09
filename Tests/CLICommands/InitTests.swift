@testable import muterCore
import XCTest

final class InitTests: MuterTestCase {
    private var directory = ""
    private lazy var sut = Init(directory: directory)

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
    }

    func test_createsAConfigurationFileNamedMuterConfYmlWithPlaceholderValuesInASpecifiedDirectory() async throws {
        try await sut.run()
        guard let contents = FileManager.default.contents(atPath: "\(directory)/muter.conf.yml"),
              (try? MuterConfiguration(from: contents)) != nil
        else {
            XCTFail("Expected a valid configuration file to be written")
            return
        }
    }

    // No run observes init, so nothing it sent was ever said: it printed nothing at all.
    func test_saysWhereItCreatedTheConfigurationFile() async throws {
        try await sut.run()

        XCTAssertTrue(printer.linesPassed.contains { $0.contains("You are running version") }, "\(printer.linesPassed)")
        XCTAssertEqual(printer.linesPassed.last, "💾 Configuration file created at: \(directory)/muter.conf.yml")
    }

    #if !os(Linux)
    // A project whose target uses a package plugin: the file it writes skips that trust check, and it says so after
    // where it wrote the file. The project is found in `directory`, not in the current folder.
    func test_aProjectUsingAPlugin_getsItsTrustCheckSkipped_andSaysSo() async throws {
        let project = "\(directory)/App.xcodeproj"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let iOSProject = try String(
            contentsOfFile: "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.pbxproj",
            encoding: .utf8
        )
        try (iOSProject + XcodebuildTrustCheckTests.projectUsingSwiftLintPlugin)
            .write(toFile: "\(project)/project.pbxproj", atomically: true, encoding: .utf8)

        try await sut.run()

        let contents = try XCTUnwrap(FileManager.default.contents(atPath: "\(directory)/muter.conf.yml"))
        let configuration = try MuterConfiguration(from: contents)
        XCTAssertEqual(configuration.testCommandArguments.prefix(2), ["-project", "App.xcodeproj"])
        XCTAssertEqual(configuration.testCommandArguments.suffix(2), ["-skipPackagePluginValidation", "test"])
        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "💾 Configuration file created at: \(directory)/muter.conf.yml",
            "⚠️ The project seems to use package plugins, so the arguments include `-skipPackagePluginValidation`: "
                + "xcodebuild then runs them without asking anyone to trust them first, which a run with no one at "
                + "the Mac, as on CI, needs. Take it out if you don't trust that code.",
        ])
    }
    #endif

    // Each check skipped, named with its argument, and nothing when none is.
    func test_trustChecksSkipped_namesEachArgument_andNothingWhenNoneIs() {
        let logger = Logger()

        logger.trustChecksSkipped([])
        XCTAssertEqual(printer.linesPassed, [])

        logger.trustChecksSkipped([.packagePlugins, .macros])
        XCTAssertEqual(printer.linesPassed, [
            "⚠️ The project seems to use package plugins and macros, so the arguments include "
                + "`-skipPackagePluginValidation` and `-skipMacroValidation`: xcodebuild then runs them without asking "
                + "anyone to trust them first, which a run with no one at the Mac, as on CI, needs. Take them out if "
                + "you don't trust that code.",
        ])
    }

    // A folder it can't write to: it says so, rather than that it created the file.
    func test_whenTheFileCantBeWritten_itSaysSo_andThrows() async throws {
        try XCTSkipIf(geteuid() == 0, "root writes to a folder whatever its permissions, as in a CI container")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        addTeardownBlock { [directory] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        }

        do {
            try await sut.run()
            XCTFail("init said it created \(directory)/muter.conf.yml")
        } catch {
            XCTAssertEqual("\(error)", "SwiftMutator could not write \(directory)/muter.conf.yml.")
        }
        XCTAssertFalse(printer.linesPassed.contains { $0.contains("Configuration file created") })
    }
}
