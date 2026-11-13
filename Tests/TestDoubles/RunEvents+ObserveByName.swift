@testable import muterCore

extension RunEvents {
    /// Calls `handler` with each event named `name` sent from now on, until the returned subscription goes.
    func observe(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) -> Subscription {
        observe { event in
            if event.name == name { handler(event) }
        }
    }
}
