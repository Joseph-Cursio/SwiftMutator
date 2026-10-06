import ArgumentParser
import Foundation

protocol RunCommand: AsyncParsableCommand {
    func run(with options: Run.Options) async throws
    func validate() throws
}

extension RunCommand {
    func run(with options: Run.Options) async throws {
        // A reader that has gone, such as a `| tee` that the same Ctrl-C ended, makes a write fail rather than end
        // SwiftMutator partway through stopping, with its test processes still running. The processes it starts
        // begin with every signal at its default action (Foundation.Process).
        signal(SIGPIPE, SIG_IGN)
        let ended = await Interruptions().run {
            try await MutationTestHandler(options: options).run()
        }
        if let error = ended.errorToShow {
            print(
                """
                ⚠️ ⚠️ ⚠️ ⚠️ ⚠️  SwiftMutator has encountered an error  ⚠️ ⚠️ ⚠️ ⚠️ ⚠️
                \(error)


                ⚠️ ⚠️ ⚠️ ⚠️ ⚠️  See the SwiftMutator error log above this line  ⚠️ ⚠️ ⚠️ ⚠️ ⚠️

                If you think this is a bug, or want help figuring out what could be happening, please open an issue at
                https://github.com/muter-mutation-testing/muter/issues
                """
            )
        }
        if let signal = ended.signal {
            // Dying by the signal tells a shell that SwiftMutator was interrupted, so a script or loop running it stops
            // too, even when an abort came first.
            Interruptions.exit(by: signal)
        }
        if case .failure = ended.result {
            Foundation.exit(-1)
        }
    }

    func validate() throws {}
}

extension Interruptions.Ended {
    /// The error a run command shows once its work has ended, if any. When a signal came, stopping has been said, and
    /// what the work threw, such as the failure of a process the stop killed, isn't shown. An abort still is: mutation
    /// testing checks for cancellation before it aborts, so no signal causes one. The abort came first, and the signal
    /// later, such as while worker clones were removed, after the summary had pointed at the error below.
    var errorToShow: Error? {
        guard case let .failure(error) = result else { return nil }
        guard signal != nil else { return error }
        guard case MuterError.mutationTestingAborted = error else { return nil }
        return error
    }
}
