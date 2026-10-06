import Foundation

/// Hears the signals that stop a run, in place of their default action, which would end SwiftMutator at once.
protocol SignalObserving: AnyObject {
    /// Calls `handler` on `queue` for each of `signals` this process receives, until `stop()`, and ignores them
    /// meanwhile. A signal that was ignored (SIG_IGN) when this was called is left alone. Returns the signals it
    /// observes.
    @discardableResult
    func start(observing signals: [Int32], on queue: DispatchQueue, handler: @escaping (Int32) -> Void) -> [Int32]
    /// Stops observing, and gives each observed signal back its earlier disposition. Call it on `queue`, so that no
    /// handler is under way.
    func stop()
}

/// Observes signals with Dispatch signal sources.
final class DispatchSignalObserver: SignalObserving {
    private var sources: [DispatchSourceSignal] = []
    private var earlier: [Int32: sigaction] = [:]

    @discardableResult
    func start(observing signals: [Int32], on queue: DispatchQueue, handler: @escaping (Int32) -> Void) -> [Int32] {
        var observed: [Int32] = []
        for number in signals {
            var current = sigaction()
            // One ignored when SwiftMutator started stays ignored and unobserved, so that a run under `nohup` outlives
            // its terminal. A signal source would hear it even so.
            guard sigaction(number, nil, &current) == 0, !Self.isIgnored(current) else { continue }
            earlier[number] = current
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { handler(number) }
            // A signal source hears a signal but doesn't stop its default action, which would end the process. Ignored
            // before the source resumes: a signal in between is lost rather than ending the process, and from
            // `resume()` on the source hears every one.
            Foundation.signal(number, SIG_IGN)
            source.resume()
            sources.append(source)
            observed.append(number)
        }
        return observed
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        for (number, action) in earlier {
            var restored = action
            sigaction(number, &restored, nil)
        }
        earlier = [:]
    }

    static func isIgnored(_ action: sigaction) -> Bool {
        handlerAddress(of: action) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    /// The handler `action` sets, as an integer, since C function pointers aren't Equatable: SIG_DFL is 0, and
    /// SIG_IGN 1.
    static func handlerAddress(of action: sigaction) -> Int {
        #if canImport(Darwin)
        let handler = action.__sigaction_u.__sa_handler
        #else
        let handler = action.__sigaction_handler.sa_handler // untested: CI runs on macOS only
        #endif
        return handler.map { unsafeBitCast($0, to: Int.self) } ?? 0
    }
}
