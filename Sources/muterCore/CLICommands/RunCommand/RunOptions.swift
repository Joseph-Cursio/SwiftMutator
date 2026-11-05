import Foundation

typealias ReportOptions = (reporter: Reporter, path: String?)

extension Run {
    /// Sendable: the command makes them, and the run's work reads them in a task of its own (`Interruptions.run`).
    struct Options: Sendable {
        let reportOptions: ReportOptions
        let filesToMutate: [String]
        /// `--since`'s git ref: only the Swift files changed since its merge base with HEAD are mutated.
        let since: String?
        /// `--changed-lines`: of those, only the code on the lines the change added or changed.
        let changedLinesOnly: Bool
        /// `--shard`: of the mutants discovered, only those in this shard are tested.
        let shard: Shard?
        /// `--sample` and `--seed`: of the mutants discovered, before any shard is taken, only this sample is tested.
        let sample: Sample?
        let mutationOperatorsList: MutationOperatorList
        /// Whether `mutationOperatorsList` is what `--operators` named, which wins over the configuration's keys.
        let operatorsAreNamed: Bool
        /// `--skip-operators`: the operators to leave out, in place of `skipOperators`; nil when it wasn't given.
        let skipOperators: [MutationOperator.Id]?
        let skipCoverage: Bool
        let skipUpdateCheck: Bool
        /// `--verbose`: the run lists how many mutants are in each file that has any, and the Swift files it found, if
        /// it looks for them.
        let verbose: Bool
        let configurationURL: URL?
        let testPlanURL: URL?
        /// `--workers`: how many mutants to test at once, in place of `mutationTestWorkers`.
        let workers: Int?
        /// `--timeout`: seconds before a mutant's test run is stopped, in place of `mutationTestTimeout`.
        let timeout: Double?
        /// `--fail-under`: the percent below which a finished run's score fails it, in place of `failUnder`.
        let failUnder: Double?
        /// `--property-tests`: the globs that pick out property tests, in place of `propertyTests`; nil when none was
        /// given.
        let propertyTests: [String]?
        let createTestPlan: Bool
        /// The results file, or the log folder of one of its sessions, of the run that `--resume` continues.
        let resumeURL: URL?
        /// The results file, or the log folder of one of its sessions, of the earlier run whose results `--reuse`
        /// starts from.
        let reuseURL: URL?
        /// `--resume-ignoring`'s globs, or `--reuse-ignoring`'s: project files that changed, whose changes a resume or
        /// a reuse lets through. A reuse never lets a test file's through.
        let resumeIgnoring: [String]
        /// `--force-resume`, or `--force-reuse`: a resume or a reuse lets a changed SwiftMutator build, toolchain or
        /// SDK through.
        let forceResume: Bool
        /// `--plan-ignoring`'s globs: files a test plan mutates that changed in the project since the plan was made,
        /// whose changes a run of the plan lets through.
        let planIgnoring: [String]
        /// `--mutant`: the one mutant the run tests, on its own (`SelectMutant`).
        let mutant: MutantReference?
        var isUsingTestPlan: Bool {
            testPlanURL != nil
        }

        /// The results file, or its log folder, whose results this run starts from: the one it resumes or reuses.
        var continuedFrom: URL? {
            resumeURL ?? reuseURL
        }

        /// Whether the run starts a results file of its own from an earlier run's (`--reuse`).
        var isReuse: Bool {
            resumeURL == nil && reuseURL != nil
        }

        init(
            filesToMutate: [String] = [],
            since: String? = nil,
            changedLinesOnly: Bool = false,
            shard: Shard? = nil,
            sample: Sample? = nil,
            reportFormat: ReportFormat = .plain,
            reportURL: URL? = nil,
            mutationOperatorsList: MutationOperatorList = .allOperators,
            operatorsAreNamed: Bool = false,
            skipOperators: [MutationOperator.Id]? = nil,
            skipCoverage: Bool,
            skipUpdateCheck: Bool,
            verbose: Bool = false,
            configurationURL: URL?,
            testPlanURL: URL? = nil,
            workers: Int? = nil,
            timeout: Double? = nil,
            failUnder: Double? = nil,
            propertyTests: [String]? = nil,
            createTestPlan: Bool = false,
            resumeURL: URL? = nil,
            reuseURL: URL? = nil,
            resumeIgnoring: [String] = [],
            forceResume: Bool = false,
            planIgnoring: [String] = [],
            mutant: MutantReference? = nil
        ) {
            self.since = since
            self.changedLinesOnly = changedLinesOnly
            self.shard = shard
            self.sample = sample
            self.skipCoverage = skipCoverage
            self.skipUpdateCheck = skipUpdateCheck
            self.verbose = verbose
            self.createTestPlan = createTestPlan
            self.mutationOperatorsList = mutationOperatorsList
            self.operatorsAreNamed = operatorsAreNamed
            self.skipOperators = skipOperators
            self.configurationURL = configurationURL
            self.testPlanURL = testPlanURL
            self.workers = workers
            self.timeout = timeout
            self.failUnder = failUnder
            self.propertyTests = propertyTests
            self.resumeURL = resumeURL
            self.reuseURL = reuseURL
            self.resumeIgnoring = resumeIgnoring
            self.forceResume = forceResume
            self.planIgnoring = planIgnoring
            self.mutant = mutant

            self.filesToMutate = filesToMutate.reduce(into: []) { accum, next in
                accum.append(
                    contentsOf: next.components(separatedBy: ",")
                        .exclude { $0.isEmpty }
                )
            }

            reportOptions = ReportOptions(
                reporter: reportFormat.reporter,
                path: reportURL?.path
            )
        }
    }
}
extension Run.Options: Equatable {
    static func == (lhs: Run.Options, rhs: Run.Options) -> Bool {
        lhs.filesToMutate == rhs.filesToMutate &&
            lhs.since == rhs.since &&
            lhs.changedLinesOnly == rhs.changedLinesOnly &&
            lhs.shard == rhs.shard &&
            lhs.sample == rhs.sample &&
            lhs.mutationOperatorsList == rhs.mutationOperatorsList &&
            lhs.operatorsAreNamed == rhs.operatorsAreNamed &&
            lhs.skipOperators == rhs.skipOperators &&
            lhs.skipCoverage == rhs.skipCoverage &&
            lhs.skipUpdateCheck == rhs.skipUpdateCheck &&
            lhs.verbose == rhs.verbose &&
            lhs.configurationURL == rhs.configurationURL &&
            lhs.testPlanURL == rhs.testPlanURL &&
            lhs.workers == rhs.workers &&
            lhs.timeout == rhs.timeout &&
            lhs.failUnder == rhs.failUnder &&
            lhs.propertyTests == rhs.propertyTests &&
            lhs.createTestPlan == rhs.createTestPlan &&
            lhs.resumeURL == rhs.resumeURL &&
            lhs.reuseURL == rhs.reuseURL &&
            lhs.resumeIgnoring == rhs.resumeIgnoring &&
            lhs.forceResume == rhs.forceResume &&
            lhs.planIgnoring == rhs.planIgnoring &&
            lhs.mutant == rhs.mutant &&
            lhs.reportOptions.path == rhs.reportOptions.path &&
            "\(lhs.reportOptions.reporter)" == "\(rhs.reportOptions.reporter)"
    }
}

extension Run.Options: Nullable {
    static var null: Run.Options {
        .init(
            filesToMutate: [],
            since: nil,
            changedLinesOnly: false,
            shard: nil,
            sample: nil,
            reportFormat: .plain,
            reportURL: nil,
            mutationOperatorsList: [],
            skipCoverage: false,
            skipUpdateCheck: false,
            verbose: false,
            configurationURL: nil,
            testPlanURL: nil,
            workers: nil,
            timeout: nil,
            failUnder: nil,
            createTestPlan: false,
            resumeURL: nil,
            reuseURL: nil,
            resumeIgnoring: [],
            forceResume: false,
            planIgnoring: [],
            mutant: nil
        )
    }
}
