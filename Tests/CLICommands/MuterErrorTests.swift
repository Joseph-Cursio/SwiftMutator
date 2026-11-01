@testable import muterCore
import Rainbow
import XCTest

/// What each error says, which `RunCommand.message(showing:)` prints inside the bug-report banner. Read without colour
/// codes (`raw`).
final class MuterErrorTests: XCTestCase {
    private static let reason = "The file “muter.conf.yml” couldn’t be opened."

    /// One of each case, with a reason where it takes one.
    private static let everyCase: [MuterError] = [
        .configurationParsingError(reason: reason),
        .projectCopyFailed(reason: reason),
        .noSourceFilesDiscovered,
        .noSourceFilesOnExclusiveList,
        .noMutationPointsDiscovered,
        .mutationTestingAborted(reason: .tooManyBuildErrors),
        .literal(reason: reason),
        .removeProjectFromPreviousRunFailed(reason: reason),
        .createTempDirectoryUrlFailed(reason: reason),
    ]

    // A case added to MuterError and not here fails to compile in `name(of:)`, so each one gets a message tested.
    func test_everyCase_saysSomething() {
        XCTAssertEqual(Set(Self.everyCase.map(name(of:))).count, Self.everyCase.count, "one of each case")
        for error in Self.everyCase {
            XCTAssertFalse(error.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name(of: error))
        }
    }

    // The reason is what tells the user what went wrong: each case that takes one says it, as it was given.
    func test_eachReason_isSaid() {
        for error in Self.everyCase where error.reason != nil {
            XCTAssertTrue(error.description.contains(Self.reason), name(of: error))
        }
    }

    func test_aConfigurationThatCantBeParsed_namesTheFile_andHowToMakeOne() {
        let description = MuterError.configurationParsingError(reason: Self.reason).description.raw

        XCTAssertTrue(description.contains("SwiftMutator was unable to parse your configuration file."), description)
        XCTAssertTrue(description.contains(MuterConfiguration.fileNameWithExtension), description)
        XCTAssertTrue(description.contains("swift-mutator init"), description)
        XCTAssertTrue(description.contains("FileManager Error:\n\(Self.reason)"), description)
    }

    func test_aFailedCopy_saysWhatToTry_andWhatToReport() {
        let description = MuterError.projectCopyFailed(reason: Self.reason).description

        XCTAssertTrue(description.hasPrefix("SwiftMutator was unable to create a temporary directory, or was unable to copy"))
        XCTAssertTrue(description.contains("Try running SwiftMutator again"), description)
        XCTAssertTrue(description.hasSuffix("FileManager error: \(Self.reason)"), description)
    }

    // Excludes are the likeliest reason nothing was found, so the message points at them.
    func test_nothingToMutate_pointsAtTheExcludes_orTheFilesToMutate() {
        for error in [MuterError.noSourceFilesDiscovered, .noMutationPointsDiscovered] {
            XCTAssertTrue(error.description.contains("wasn't able to discover any code it could mutation test"), "\(error)")
            XCTAssertTrue(error.description.contains("excluding a directory that contains your code"), "\(error)")
        }
        XCTAssertEqual(
            MuterError.noSourceFilesOnExclusiveList.description,
            """
            SwiftMutator wasn't able to discover any Swift file on the list provided by the `--files-to-mutate` flag.

            Please check the list of files and try again.
            """
        )
    }

    // An abort says only its reason, which says what happened and what to do.
    func test_anAbort_isItsReason() {
        let reasons: [MutationTestingAbortReason] = [
            .tooManyBuildErrors,
            .unknownError(description: "the delegate stopped"),
            .workerBaselineTestFailed(worker: 2, directory: "/p_mutated_worker_2", log: "error: no such module"),
        ]
        for reason in reasons {
            XCTAssertEqual(MuterError.mutationTestingAborted(reason: reason).description, "\(reason)")
        }
    }

    func test_aLiteral_isItsReason_asItIs() {
        let reason = "Please provide the path to the test plan json."
        XCTAssertEqual(MuterError.literal(reason: reason).description, reason)
        XCTAssertEqual(MuterError.literal(reason: "").description, "")
    }

    func test_theFolderErrors_sayWhichStepFailed() {
        let removal = MuterError.removeProjectFromPreviousRunFailed(reason: Self.reason).description
        XCTAssertTrue(removal.hasPrefix("SwiftMutator wasn't able to remove project from previous run."), removal)
        XCTAssertTrue(removal.hasSuffix("FileManager Error: \(Self.reason)"), removal)

        let creation = MuterError.createTempDirectoryUrlFailed(reason: Self.reason).description
        XCTAssertTrue(creation.hasPrefix("SwiftMutator wasn't able to create a temporary directory."), creation)
        XCTAssertTrue(creation.hasSuffix("FileManager Error: \(Self.reason)"), creation)
    }

    // Tests compare errors, so equality covers each case's associated value.
    func test_equality_comparesTheCaseAndItsValue() {
        XCTAssertEqual(MuterError.literal(reason: "a"), .literal(reason: "a"))
        XCTAssertNotEqual(MuterError.literal(reason: "a"), .literal(reason: "b"))
        XCTAssertNotEqual(MuterError.projectCopyFailed(reason: "a"), .removeProjectFromPreviousRunFailed(reason: "a"))
        XCTAssertNotEqual(
            MuterError.mutationTestingAborted(reason: .tooManyBuildErrors),
            .mutationTestingAborted(reason: .unknownError(description: ""))
        )
    }

    private func name(of error: MuterError) -> String {
        switch error {
        case .configurationParsingError: "configurationParsingError"
        case .projectCopyFailed: "projectCopyFailed"
        case .noSourceFilesDiscovered: "noSourceFilesDiscovered"
        case .noSourceFilesOnExclusiveList: "noSourceFilesOnExclusiveList"
        case .noMutationPointsDiscovered: "noMutationPointsDiscovered"
        case .mutationTestingAborted: "mutationTestingAborted"
        case .literal: "literal"
        case .removeProjectFromPreviousRunFailed: "removeProjectFromPreviousRunFailed"
        case .createTempDirectoryUrlFailed: "createTempDirectoryUrlFailed"
        }
    }
}

private extension MuterError {
    /// The reason the case was given, if it takes one.
    var reason: String? {
        switch self {
        case let .configurationParsingError(reason), let .projectCopyFailed(reason), let .literal(reason),
             let .removeProjectFromPreviousRunFailed(reason), let .createTempDirectoryUrlFailed(reason):
            reason
        case .noSourceFilesDiscovered, .noSourceFilesOnExclusiveList, .noMutationPointsDiscovered, .mutationTestingAborted:
            nil
        }
    }
}
