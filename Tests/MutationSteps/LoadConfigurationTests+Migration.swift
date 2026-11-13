@testable import muterCore
import XCTest

extension LoadConfigurationTests {
    func test_migrationToYaml() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertTrue(fileManager.methodCalls.contains("removeItem(atPath:)"))
        XCTAssertTrue(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        assertConfigurationsEquals(
            fileManager.contents,
            loadYAMLConfiguration()
        )
    }

    // Not `/muter.conf.json`, at the root of the disk, which real runs read until it was fixed. This spy returns its
    // contents for any path, so only the path shows it.
    func test_migration_readsAndReplacesTheLegacyFile_inTheProject() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()

        _ = try await sut.run(with: state)

        let legacy = "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        XCTAssertEqual(fileManager.contentsAtPath.first, legacy)
        XCTAssertEqual(
            Array(fileManager.createdFiles.keys),
            ["\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"]
        )
        XCTAssertEqual(fileManager.paths.last, legacy)
    }

    func test_migration_inACustomFolder_staysThere() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        state.runOptions = .make(configurationURL: URL(fileURLWithPath: "/some/custom/path"))

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsAtPath.first, "/some/custom/path/muter.conf.json")
        XCTAssertEqual(Array(fileManager.createdFiles.keys), ["/some/custom/path/muter.conf.yml"])
        XCTAssertEqual(fileManager.paths.last, "/some/custom/path/muter.conf.json")
    }

    // Migrating would overwrite the YAML file with the legacy file's older settings.
    func test_aYAMLFile_winsOverALegacyFile_whichStays() async throws {
        fileManager.fileExistsToReturn = [true, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.contentsAtPath.first,
            "\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"
        )
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
        XCTAssertEqual(fileManager.createdFiles, [:])
    }

    func test_aFailedMigration_keepsTheLegacyFile() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        fileManager.createFileToReturn = false

        _ = try await sut.run(with: state)

        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }

    func test_aMissingFileThatConfigurationNames_isNotReplacedByALegacyFile() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        state.runOptions = .make(configurationURL: URL(fileURLWithPath: "/some/custom/other.yml"))

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("/some/custom/other.yml"), "\(error)")
        }
        XCTAssertEqual(fileManager.contentsAtPath, [])
        XCTAssertEqual(fileManager.createdFiles, [:])
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }
}
