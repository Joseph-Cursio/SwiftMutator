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
    /// Whether the xcodebuild in use lists `-collect-test-diagnostics never` in its `-help`; false until
    /// `BuildForTesting` has asked it, and for other build systems.
    var testDiagnosticsCanBeTurnedOff: Bool { get }
    var projectCoverage: Coverage { get }
    var sourceFileCandidates: [FilePath] { get }
    var mutationPoints: [MutationPoint] { get }
    var mutationMapping: [SchemataMutationMapping] { get }
    var droppedMutants: [DroppedMutant] { get }
    var sourceCodeByFilePath: [FilePath: SourceFileSyntax] { get }
    var filesToMutate: [String] { get }
    var mutationTestOutcome: MutationTestOutcome { get }
    /// The folder the run's test logs are kept in, `<project>_muter_logs/<timestamp>`, so a step can keep other
    /// files of the run beside them; "" until the handler has created it.
    var loggingDirectory: String { get }
    /// The project's files as the copy held them before discovery rewrote it, or in a run that tests a test plan, as
    /// the plan's copy holds them, rewritten and with any fix made by hand; nil until the copy is fingerprinted.
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
    /// The files, and with `--changed-lines` the lines, that `--since` chose; nil without `--since`.
    var changeSelection: ChangeSelection? { get }
    /// Which shard `--shard` tests, and what discovery found in every shard; nil without `--shard`, and until
    /// discovery.
    var shardSelection: ShardSelection? { get }
    /// Which mutants `--sample` tests, and of how many; nil without `--sample`, and until discovery.
    var sampleSelection: SampleSelection? { get }
    /// The keys of the mutants discovery found and `--sample` left out, which a resume or a reuse tells from mutants
    /// no longer discovered; empty without `--sample`.
    var keysLeftOutOfTheSample: Set<MutantKey> { get }
    /// The paths in the mutated project, relative to it, that discovery picks from, once listed before coverage is
    /// gathered, as a `--since` run lists them; nil until then, when discovery lists them itself.
    var candidatePaths: [FilePath]? { get }
    /// The test plan the run tests; nil until it is loaded, and in a run that tests none.
    var testPlan: LoadedTestPlan? { get }
    /// The one mutant `--mutant` chose, which is then the only one in `mutationMapping`; nil without `--mutant`, and
    /// until it is chosen.
    var selectedMutant: MutantKey? { get }
    /// Each file with mutants as discovery prepared it, by its path in the copy, which `ApplySchemata` overwrites, so
    /// that a mutant that doesn't compile can be left out of a new rewrite (`CompileRecovery`); empty until then, and
    /// in a run of a test plan, whose copy is what the plan was made with.
    var preparedSources: [FilePath: String] { get }
    /// The mutants, by switch ID, that `BuildForTesting` took out of the build, as they don't compile; empty for any
    /// other build system, which takes them out as its baseline builds.
    var mutantsLeftOut: [String: LeftOutMutant] { get }

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
    var testDiagnosticsCanBeTurnedOff = false
    var projectCoverage: Coverage = .null
    var sourceFileCandidates: [FilePath] = []
    var mutationPoints: [MutationPoint] = []
    var mutationMapping: [SchemataMutationMapping] = []
    var droppedMutants: [DroppedMutant] = []
    var sourceCodeByFilePath: [FilePath: SourceFileSyntax] = [:]
    var mutationTestOutcome: MutationTestOutcome = .init()
    var loggingDirectory = ""
    var projectTree: ProjectTree?
    var resumeState: ResumeState?
    var resumeWaived: [String] = []
    var reuseChanges: [Int: ReuseChanges]?
    var changeSelection: ChangeSelection?
    var shardSelection: ShardSelection?
    var sampleSelection: SampleSelection?
    var keysLeftOutOfTheSample: Set<MutantKey> = []
    var candidatePaths: [FilePath]?
    var testPlan: LoadedTestPlan?
    var selectedMutant: MutantKey?
    var preparedSources: [FilePath: String] = [:]
    var mutantsLeftOut: [String: LeftOutMutant] = [:]

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
        case testDiagnosticsOptionChecked(canBeTurnedOff: Bool)
        case projectCoverage(Coverage)
        case sourceFileCandidatesDiscovered([FilePath])
        case mutationPointsDiscovered([MutationPoint])
        case mutationMappingsDiscovered([SchemataMutationMapping])
        case mutantsDropped([DroppedMutant])
        case sourceCodeParsed([FilePath: SourceFileSyntax])
        case mutationTestOutcomeGenerated(MutationTestOutcome)
        case loggingDirectoryCreated(String)
        case projectTreeFingerprinted(ProjectTree)
        case resumeStateLoaded(ResumeState)
        case projectChangesWaived([String])
        case reuseChangesFound([Int: ReuseChanges])
        case changesSelected(ChangeSelection)
        case shardSelected(ShardSelection)
        case sampleSelected(SampleSelection)
        case sampleLeftOut(Set<MutantKey>)
        case candidatePathsListed([FilePath])
        case testPlanLoaded(LoadedTestPlan)
        case mutantSelected(MutantKey)
        case operatorsChosen(MutationOperatorList)
        case preparedSourcesKept([FilePath: String])
        case mutantsLeftOutOfTheBuild([String: LeftOutMutant])
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
            case let .testDiagnosticsOptionChecked(canBeTurnedOff):
                testDiagnosticsCanBeTurnedOff = canBeTurnedOff
            case let .projectCoverage(projectCoverage):
                self.projectCoverage = projectCoverage
            case let .sourceFileCandidatesDiscovered(sourceFileCandidates):
                self.sourceFileCandidates = sourceFileCandidates
            case let .mutationPointsDiscovered(mutationPoints):
                self.mutationPoints = mutationPoints
            case let .mutationMappingsDiscovered(mutationMapping):
                self.mutationMapping = mutationMapping
            case let .mutantsDropped(droppedMutants):
                self.droppedMutants = droppedMutants
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
            case let .changesSelected(selection):
                changeSelection = selection
            case let .shardSelected(selection):
                shardSelection = selection
            case let .sampleSelected(selection):
                sampleSelection = selection
            case let .sampleLeftOut(keys):
                keysLeftOutOfTheSample = keys
            case let .candidatePathsListed(paths):
                candidatePaths = paths
            case let .testPlanLoaded(plan):
                testPlan = plan
                // So the results file, and a resume's check, describe the plan's mutants, not the command's defaults.
                if let scope = plan.scope {
                    mutationOperatorList = scope.operators
                    filesToMutate = scope.filesToMutate
                }
            case let .mutantSelected(key):
                selectedMutant = key
            case let .operatorsChosen(operators):
                mutationOperatorList = operators
            case let .preparedSourcesKept(sources):
                preparedSources = sources
            case let .mutantsLeftOutOfTheBuild(mutants):
                mutantsLeftOut = mutants
            }
        }
    }
}
