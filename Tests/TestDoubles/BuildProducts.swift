import Foundation

/// The folder of the build's products: the test bundle, and the `swift-mutator` that `swift test` builds beside it.
enum BuildProducts {
    static var folder: URL? {
        #if os(Linux)
        // Linux's XCTest runs the tests as an executable of their own, not as a bundle that a runner loads.
        Bundle.main.executableURL?.deletingLastPathComponent()
        #else
        Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
        #endif
    }
}
