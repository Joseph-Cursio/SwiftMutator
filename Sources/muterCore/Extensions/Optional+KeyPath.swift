import Foundation

extension Optional {
    func map<Value>(_ keyPath: KeyPath<Wrapped, Value>) -> Value? {
        map { $0[keyPath: keyPath] }
    }
}
