import Foundation

/// Why SwiftMutator won't test a test plan: it might not describe the project, or can't be tested as it is. Nothing was
/// tested.
struct TestPlanRefused: Error, Equatable, CustomStringConvertible {
    /// The plan's path.
    let path: String
    let reason: TestPlanRefusal

    var description: String {
        "SwiftMutator won't test the plan \(Logger.shellQuoted(path)): \(reason) Nothing was tested."
    }
}

/// One reason a test plan isn't tested, and what would let it be.
enum TestPlanRefusal: Equatable, CustomStringConvertible {
    /// The plan is in a format newer than `TestPlanCoding.newestFormatVersion`.
    case newerFormat(found: Int)
    /// The plan's copy of the project, at this absolute path, isn't there.
    case copyMissing(path: String)

    var description: String {
        switch self {
        case let .newerFormat(found):
            return "it is in test plan format \(found), which only a newer SwiftMutator can read. Test it with the "
                + "SwiftMutator that made it, or make it again with `swift-mutator mutate-without-running`."
        case let .copyMissing(path):
            return "its copy of the project, \(path), isn't there. A later `swift-mutator run` or "
                + "`swift-mutator mutate-without-running` of the project removes it. Make the plan again with "
                + "`swift-mutator mutate-without-running`."
        }
    }
}
