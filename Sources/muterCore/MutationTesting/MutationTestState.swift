import Foundation
import SwiftSyntax

protocol AnyMutationTestState: AnyObject {
    var runOptions: Run.Options { get }
    var newVersion: String { get }
    var mutationTestingStartTime: Date { get }
    var muterConfiguration: MuterConfiguration { get }
    var mutationOperatorList: MutationOperatorList { get }
    var projectDirectoryURL: URL { get }
    var mutatedProjectDirectoryURL: URL { get }
    /// The lock on the mutated project, held until the state goes once the run's work has ended; nil until taken.
    var mutatedProjectLock: MutatedProjectLock? { get }
    var projectXCTestRun: XCTestRun { get }
    var projectCoverage: Coverage { get }
    var sourceFileCandidates: [FilePath] { get }
    var mutationPoints: [MutationPoint] { get }
    var mutationMapping: [SchemataMutationMapping] { get }
    var sourceCodeByFilePath: [FilePath: SourceFileSyntax] { get }
    var filesToMutate: [String] { get }
    var mutationTestOutcome: MutationTestOutcome { get }
    /// The folder the run's test logs are kept in, `<project>_muter_logs/<timestamp>`, so a step can keep other
    /// files of the run beside them; "" until the handler has created it.
    var loggingDirectory: String { get }
    /// The project's files as the copy held them before discovery rewrote it; nil until the copy is fingerprinted,
    /// and for good in a run that tests a test plan.
    var projectTree: ProjectTree? { get }
    /// The stopped run that `--resume` continues, or the earlier run whose results `--reuse` starts from; nil when the
    /// run does neither.
    var resumeState: ResumeState? { get }
    /// The changed project files that `--resume-ignoring` or `--reuse-ignoring` let through, by their paths relative to
    /// the project.
    var resumeWaived: [String] { get }
    /// What changed since each session of the run `--reuse` starts from, by session; nil unless the run reuses one. A
    /// session that recorded no project files has none.
    var reuseChanges: [Int: ReuseChanges]? { get }

    func apply(_ stateChanges: [MutationTestState.Change])
}

final class MutationTestState: AnyMutationTestState {
    var runOptions: Run.Options = .null
    var mutationOperatorList: MutationOperatorList = []
    var filesToMutate: [String] = []
    var newVersion: String = ""
    var mutationTestingStartTime: Date = .init()
    var muterConfiguration: MuterConfiguration = .init()
    var projectDirectoryURL: URL = .init(fileURLWithPath: "path")
    var mutatedProjectDirectoryURL: URL = .init(fileURLWithPath: "path")
    var mutatedProjectLock: MutatedProjectLock?
    var projectXCTestRun: XCTestRun = .init()
    var projectCoverage: Coverage = .null
    var sourceFileCandidates: [FilePath] = []
    var mutationPoints: [MutationPoint] = []
    var mutationMapping: [SchemataMutationMapping] = []
    var sourceCodeByFilePath: [FilePath: SourceFileSyntax] = [:]
    var mutationTestOutcome: MutationTestOutcome = .init()
    var loggingDirectory = ""
    var projectTree: ProjectTree?
    var resumeState: ResumeState?
    var resumeWaived: [String] = []
    var reuseChanges: [Int: ReuseChanges]?

    init() {}

    init(from options: Run.Options) {
        runOptions = options
        mutationOperatorList = options.mutationOperatorsList
        filesToMutate = options.filesToMutate
    }
}

extension MutationTestState {
    enum Change: Equatable, Sendable {
        case newVersionAvaiable(String)
        case configurationParsed(MuterConfiguration)
        case projectDirectoryUrlDiscovered(URL)
        case tempDirectoryUrlCreated(URL)
        case mutatedProjectLocked(MutatedProjectLock)
        case projectXCTestRun(XCTestRun)
        case projectCoverage(Coverage)
        case sourceFileCandidatesDiscovered([FilePath])
        case mutationPointsDiscovered([MutationPoint])
        case mutationMappingsDiscovered([SchemataMutationMapping])
        case sourceCodeParsed([FilePath: SourceFileSyntax])
        case mutationTestOutcomeGenerated(MutationTestOutcome)
        case loggingDirectoryCreated(String)
        case projectTreeFingerprinted(ProjectTree)
        case resumeStateLoaded(ResumeState)
        case projectChangesWaived([String])
        case reuseChangesFound([Int: ReuseChanges])
    }
}

extension MutationTestState {
    func apply(_ stateChanges: [MutationTestState.Change]) {
        for change in stateChanges {
            switch change {
            case let .newVersionAvaiable(newVersion):
                self.newVersion = newVersion
            case let .configurationParsed(muterConfiguration):
                self.muterConfiguration = muterConfiguration
            case let .projectDirectoryUrlDiscovered(projectDirectoryURL):
                self.projectDirectoryURL = projectDirectoryURL
            case let .tempDirectoryUrlCreated(mutatedProjectDirectoryURL):
                self.mutatedProjectDirectoryURL = mutatedProjectDirectoryURL
            case let .mutatedProjectLocked(mutatedProjectLock):
                self.mutatedProjectLock = mutatedProjectLock
            case let .projectXCTestRun(projectXCTestRun):
                self.projectXCTestRun = projectXCTestRun
            case let .projectCoverage(projectCoverage):
                self.projectCoverage = projectCoverage
            case let .sourceFileCandidatesDiscovered(sourceFileCandidates):
                self.sourceFileCandidates = sourceFileCandidates
            case let .mutationPointsDiscovered(mutationPoints):
                self.mutationPoints = mutationPoints
            case let .mutationMappingsDiscovered(mutationMapping):
                self.mutationMapping = mutationMapping
            case let .sourceCodeParsed(sourceCodeByFilePath):
                self.sourceCodeByFilePath = sourceCodeByFilePath
            case let .mutationTestOutcomeGenerated(mutationTestOutcome):
                self.mutationTestOutcome = mutationTestOutcome
            case let .loggingDirectoryCreated(loggingDirectory):
                self.loggingDirectory = loggingDirectory
            case let .projectTreeFingerprinted(projectTree):
                self.projectTree = projectTree
            case let .resumeStateLoaded(resumeState):
                self.resumeState = resumeState
            case let .projectChangesWaived(paths):
                resumeWaived = paths
            case let .reuseChangesFound(changes):
                reuseChanges = changes
            }
        }
    }
}
