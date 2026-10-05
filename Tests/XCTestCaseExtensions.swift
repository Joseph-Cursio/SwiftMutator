@testable import muterCore
import TestingExtensions
import XCTest

class MuterTestCase: XCTestCase {
    private(set) var notificationCenter: NotificationCenter = .init()
    private(set) var fileManager = FileManagerSpy()
    private(set) var ioDelegate = MutationTestingDelegateSpy()
    private(set) var prepareCode = SourceCodePreparationSub()
    private(set) var process = ProcessSpy()
    private(set) var flushStandardOut = FlushHandlerSpy()
    private(set) var server = ServerSpy()
    private(set) var writeFile = WriteFileSpy()
    private(set) var printer = PrinterSpy()
    private(set) var testingTimeOutExecutor = TestingTimeOutExecutorSpy()
    private(set) var resultsFiles = ResultsFilesSpy()

    private let fixedNow = DateComponents(
        calendar: .init(identifier: .gregorian),
        year: 2021,
        month: 1,
        day: 20,
        hour: 2,
        minute: 42
    ).date!

    override func setUp() {
        super.setUp()

        setup()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        setup()
    }

    private func setup() {
        current = World(
            notificationCenter: notificationCenter,
            fileManager: fileManager,
            flushStandardOut: flushStandardOut.flush,
            printer: printer.print,
            ioDelegate: ioDelegate,
            process: { self.process },
            prepareCode: prepareCode.prepare,
            writeFile: writeFile.writeFile,
            server: server,
            now: { self.fixedNow },
            instant: { DispatchTime(uptimeNanoseconds: 1) },
            testingTimeOutExecutor: { self.testingTimeOutExecutor },
            provenance: { _ in .fixture },
            resultsFiles: resultsFiles
        )
    }

    func generateSchemataMappings(
        for source: SourceCodeInfo,
        changes: MutationSourceCodePreparationChange = .null,
        regionsWithoutCoverage: [Region] = []
    ) -> [SchemataMutationMapping] {
        MutationOperator.Id.allCases
            .accumulate(into: []) { newSchemataMappings, mutationOperatorId in
                let visitor = mutationOperatorId.visitor(
                    .init(),
                    source,
                    regionsWithoutCoverage
                )

                visitor.sourceCodePreparationChange = changes

                visitor.walk(source.code)

                let schemataMapping = visitor.schemataMappings

                if !schemataMapping.isEmpty {
                    return newSchemataMappings + [schemataMapping]
                } else {
                    return newSchemataMappings
                }
            }.mergeByFilePath()
    }

    func assertThrowsMuterError(
        _ expression: @autoclosure () async throws -> some Any,
        _ expectedError: MuterError,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        try await assertThrowsMuterError(
            await expression(),
            message(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error, expectedError, file: file, line: line)
        }
    }

    func assertThrowsMuterError(
        _ expression: @autoclosure () async throws -> some Any,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (MuterError) throws -> Void
    ) async {
        try await AssertThrowsError(
            await expression(),
            message(),
            file: file,
            line: line
        ) { error in
            if let muterError = error as? MuterError {
                try errorHandler(muterError)
            } else {
                XCTFail("Expected \(MuterError.self), got \(error)", file: file, line: line)
            }
        }
    }

    func loadFixture(_ path: String) -> String {
        FileManager.default
            .contents(atPath: "\(fixturesDirectory)/\(path)")
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
    }
}

public extension XCTestCase {
    var rootTestDirectory: String {
        String(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .withoutScheme()
        )
    }

    var fixturesDirectory: String { "\(rootTestDirectory)/fixtures" }
    var configurationPath: String { "\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)" }
    var mutationExamplesDirectory: String { "\(fixturesDirectory)/MutationExamples" }
}

extension XCTestCase {
    /// A new, empty directory, removed when the test finishes. A test that writes files uses one
    /// rather than a folder next to its source: every process running the same compiled tests finds
    /// that folder at the same `#filePath`, so when mutation testing runs the suite in several
    /// processes at once, the copies overwrite and delete each other's files and fail.
    func makeTemporaryDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory
    }

    /// A new, empty directory that can also be reached through a symbolic link, the way `/private/tmp`
    /// is also `/tmp` on macOS. Both are removed when the test finishes.
    func makeDirectoryWithSymbolicLink() throws -> (directory: String, link: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let directory = "\(root)/directory"
        let link = "\(root)/link"

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        return (directory, link)
    }
}
