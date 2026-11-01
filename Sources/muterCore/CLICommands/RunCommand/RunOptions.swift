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
        let mutationOperatorsList: MutationOperatorList
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
        let createTestPlan: Bool
        /// The results file, or the log folder that holds it, of the run that `--resume` continues.
        let resumeURL: URL?
        /// The results file, or the log folder that holds it, of the earlier run whose results `--reuse` starts from.
        let reuseURL: URL?
        /// `--resume-ignoring`'s globs, or `--reuse-ignoring`'s: project files that changed, whose changes a resume or a
        /// reuse lets through. A reuse never lets a test file's through.
        let resumeIgnoring: [String]
        /// `--force-resume`, or `--force-reuse`: a resume or a reuse lets a changed SwiftMutator build, toolchain or SDK
        /// through.
        let forceResume: Bool
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
            reportFormat: ReportFormat = .plain,
            reportURL: URL? = nil,
            mutationOperatorsList: MutationOperatorList = .allOperators,
            skipCoverage: Bool,
            skipUpdateCheck: Bool,
            verbose: Bool = false,
            configurationURL: URL?,
            testPlanURL: URL? = nil,
            workers: Int? = nil,
            timeout: Double? = nil,
            createTestPlan: Bool = false,
            resumeURL: URL? = nil,
            reuseURL: URL? = nil,
            resumeIgnoring: [String] = [],
            forceResume: Bool = false
        ) {
            self.since = since
            self.changedLinesOnly = changedLinesOnly
            self.skipCoverage = skipCoverage
            self.skipUpdateCheck = skipUpdateCheck
            self.verbose = verbose
            self.createTestPlan = createTestPlan
            self.mutationOperatorsList = mutationOperatorsList
            self.configurationURL = configurationURL
            self.testPlanURL = testPlanURL
            self.workers = workers
            self.timeout = timeout
            self.resumeURL = resumeURL
            self.reuseURL = reuseURL
            self.resumeIgnoring = resumeIgnoring
            self.forceResume = forceResume

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
            lhs.mutationOperatorsList == rhs.mutationOperatorsList &&
            lhs.skipCoverage == rhs.skipCoverage &&
            lhs.skipUpdateCheck == rhs.skipUpdateCheck &&
            lhs.verbose == rhs.verbose &&
            lhs.configurationURL == rhs.configurationURL &&
            lhs.testPlanURL == rhs.testPlanURL &&
            lhs.workers == rhs.workers &&
            lhs.timeout == rhs.timeout &&
            lhs.createTestPlan == rhs.createTestPlan &&
            lhs.resumeURL == rhs.resumeURL &&
            lhs.reuseURL == rhs.reuseURL &&
            lhs.resumeIgnoring == rhs.resumeIgnoring &&
            lhs.forceResume == rhs.forceResume &&
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
            createTestPlan: false,
            resumeURL: nil,
            reuseURL: nil,
            resumeIgnoring: [],
            forceResume: false
        )
    }
}
