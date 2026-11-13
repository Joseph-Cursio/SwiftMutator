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

    // A second init would lose a file edited by hand: it says how to replace it, and leaves it as it is.
    func test_aFileThatIsAlreadyThere_isLeftAlone_unlessForced() async throws {
        let path = "\(directory)/muter.conf.yml"
        try "executable: /usr/bin/swift\narguments: [test]\n# mine\n".write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )

        do {
            try await sut.run()
            XCTFail("init replaced \(path)")
        } catch {
            XCTAssertEqual(
                "\(error)",
                "\(path) is already there, so init left it as it is. `swift-mutator init --force` replaces it."
            )
        }
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("# mine"))

        var forced = Init(directory: directory, force: true)
        try await forced.run()
        XCTAssertFalse(try String(contentsOfFile: path, encoding: .utf8).contains("# mine"))
    }

    // `--force` is the only flag.
    func test_parsesForce() throws {
        XCTAssertFalse(try Init.parse([]).force)
        XCTAssertTrue(try Init.parse(["--force"]).force)
    }

    // Every key, with a comment, and those at their defaults commented out: no `coverageThreshold: 0e+0`.
    func test_writesEveryKeyWithAComment() async throws {
        try await sut.run()

        let text = try String(contentsOfFile: "\(directory)/muter.conf.yml", encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# SwiftMutator's configuration, written by `swift-mutator init`."), text)
        XCTAssertTrue(text.contains("\n# coverageThreshold: 0\n"), text)
        XCTAssertFalse(text.contains("0e+0"), text)
    }

    // A scheme init chose among several, none named after the project, or guessed with none listed.
    func test_schemeGuessed_saysSo_onlyForAGuess() {
        let logger = Logger()

        logger.schemeGuessed(nil)
        logger.schemeGuessed(SchemeChoice(listed: ["Shop"], containerName: "Shop"))
        XCTAssertEqual(printer.linesPassed, [])

        logger.schemeGuessed(SchemeChoice(listed: ["Core", "Shop App"], containerName: "Shop"))
        logger.schemeGuessed(SchemeChoice(listed: [], containerName: "Shop"))
        XCTAssertEqual(printer.linesPassed, [
            "⚠️ No scheme is named after Shop, so the arguments take `-scheme Core`, the first of Core, Shop App. "
                + "Change it in muter.conf.yml if another one runs your tests.",
            "⚠️ xcodebuild -list named no scheme, so the arguments take `-scheme Shop`, the workspace's or "
                + "project's name. Check it in muter.conf.yml.",
        ])
    }

    // No run observes init, so nothing it sent was ever said: it printed nothing at all.
    func test_saysWhereItCreatedTheConfigurationFile() async throws {
        try await sut.run()

        XCTAssertTrue(printer.linesPassed.contains { $0.contains("You are running version") }, "\(printer.linesPassed)")
        XCTAssertEqual(printer.linesPassed.last, "💾 Configuration file created at: \(directory)/muter.conf.yml")
    }

    #if !os(Linux)
    // A project whose target uses a package plugin: the file it writes skips that trust check, and it says so after
    // where it wrote the file. The project is found in `directory`, not in the current folder, and though `directory`
    // is in a folder named like a dependency's checkout, its own files are read.
    func test_aProjectUsingAPlugin_getsItsTrustCheckSkipped_andSaysSo() async throws {
        directory += "/SourcePackages/App"
        let project = "\(directory)/App.xcodeproj"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let iOSProject = try String(
            contentsOfFile: "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.pbxproj",
            encoding: .utf8
        )
        try (iOSProject + XcodebuildTrustCheckTests.projectUsingSwiftLintPlugin)
            .write(toFile: "\(project)/project.pbxproj", atomically: true, encoding: .utf8)
        process.stdoutToBeReturned = #"{ "project" : { "name" : "App", "schemes" : [ "App" ] } }"#

        try await sut.run()

        let contents = try XCTUnwrap(FileManager.default.contents(atPath: "\(directory)/muter.conf.yml"))
        let configuration = try MuterConfiguration(from: contents)
        XCTAssertEqual(configuration.testCommandArguments.prefix(2), ["-project", "App.xcodeproj"])
        XCTAssertEqual(configuration.testCommandArguments[4], "-skipPackagePluginValidation")
        XCTAssertEqual(configuration.testCommandArguments.last, "test")
        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "💾 Configuration file created at: \(directory)/muter.conf.yml",
            "⚠️ The project seems to use package plugins, so the arguments include `-skipPackagePluginValidation`: "
                + "xcodebuild then runs them without asking anyone to trust them first, which a run with no one at "
                + "the Mac, as on CI, needs. Take the argument out of muter.conf.yml if you don't trust that code.",
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
                + "anyone to trust them first, which a run with no one at the Mac, as on CI, needs. Take the arguments "
                + "out of muter.conf.yml if you don't trust that code.",
        ])
    }

    // A folder it can't write to: it says so, rather than that it created the file.
    func test_whenTheFileCantBeWritten_itSaysSo_andThrows() async throws {
        try XCTSkipIf(geteuid() == 0, "root writes to a folder whatever its permissions, as in a CI container")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        let readOnlyFolder = directory
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyFolder)
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
