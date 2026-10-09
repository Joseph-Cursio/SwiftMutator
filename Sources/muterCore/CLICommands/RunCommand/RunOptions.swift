import Foundation

typealias ReportOptions = (reporter: Reporter, path: String?)

extension Run {
    struct Options {
        let reportOptions: ReportOptions
        let filesToMutate: [String]
        let mutationOperatorsList: MutationOperatorList
        let skipCoverage: Bool
        let skipUpdateCheck: Bool
        /// `--verbose`: the run lists how many mutants are in each file that has any, and the Swift files it found, if
        /// it looks for them.
        let verbose: Bool
        let configurationURL: URL?
        let testPlanURL: URL?
        let createTestPlan: Bool
        /// The results file, or the log folder that holds it, of the run that `--resume` continues.
        let resumeURL: URL?
        /// `--resume-ignoring`'s globs: project files that changed, whose changes a resume lets through.
        let resumeIgnoring: [String]
        /// `--force-resume`: a resume lets a changed SwiftMutator build, toolchain or SDK through.
        let forceResume: Bool
        var isUsingTestPlan: Bool {
            testPlanURL != nil
        }

        init(
            filesToMutate: [String] = [],
            reportFormat: ReportFormat = .plain,
            reportURL: URL? = nil,
            mutationOperatorsList: MutationOperatorList = .allOperators,
            skipCoverage: Bool,
            skipUpdateCheck: Bool,
            verbose: Bool = false,
            configurationURL: URL?,
            testPlanURL: URL? = nil,
            createTestPlan: Bool = false,
            resumeURL: URL? = nil,
            resumeIgnoring: [String] = [],
            forceResume: Bool = false
        ) {
            self.skipCoverage = skipCoverage
            self.skipUpdateCheck = skipUpdateCheck
            self.verbose = verbose
            self.createTestPlan = createTestPlan
            self.mutationOperatorsList = mutationOperatorsList
            self.configurationURL = configurationURL
            self.testPlanURL = testPlanURL
            self.resumeURL = resumeURL
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
            lhs.mutationOperatorsList == rhs.mutationOperatorsList &&
            lhs.skipCoverage == rhs.skipCoverage &&
            lhs.skipUpdateCheck == rhs.skipUpdateCheck &&
            lhs.verbose == rhs.verbose &&
            lhs.configurationURL == rhs.configurationURL &&
            lhs.testPlanURL == rhs.testPlanURL &&
            lhs.createTestPlan == rhs.createTestPlan &&
            lhs.resumeURL == rhs.resumeURL &&
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
            reportFormat: .plain,
            reportURL: nil,
            mutationOperatorsList: [],
            skipCoverage: false,
            skipUpdateCheck: false,
            verbose: false,
            configurationURL: nil,
            testPlanURL: nil,
            createTestPlan: false,
            resumeURL: nil,
            resumeIgnoring: [],
            forceResume: false
        )
    }
}
