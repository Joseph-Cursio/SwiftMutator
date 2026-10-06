@testable import muterCore

class MutationStepSpy: Spy, MutationStep {
    private(set) var methodCalls: [String] = []
    private(set) var states: [AnyMutationTestState] = []
    var resultToReturn: Result<[MutationTestState.Change], MuterError>!
    /// Called as each run is under way, before it returns, so a test can cancel the run of the steps meanwhile.
    var whileRunning: (() -> Void)?

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        methodCalls.append(#function)
        states.append(state)
        whileRunning?()

        switch resultToReturn {
        case let .success(result):
            return result
        case let .failure(failure):
            throw failure
        case .none:
            throw MuterError.literal(reason: #function)
        }
    }
}
