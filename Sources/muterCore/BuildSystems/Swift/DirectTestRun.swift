import Foundation

/// How a SwiftPM mutant's tests run without `swift test`: each test bundle, one after another, by the programs
/// `swift test --skip-build` starts for it, given what it gives them. `swift test` spends a fixed time of every run
/// before its first test starts, loading the package graph and planning the build it then skips: on SwiftProjectLint,
/// with three bundles, a run that matched no test took 1.26 s through `swift test` and 0.20 s this way on macOS (#62).
/// On Linux it costs 0.2 to 0.3 s a run (#281).
///
/// On macOS, `xctest` runs a bundle's XCTest tests and SwiftPM's own `swiftpm-testing-helper` its Swift Testing tests.
/// On Linux, each test target's `<target>-test-runner` runs either. XCTest tests run only in the bundles whose
/// baseline ran some (`xctestBundles`), and only without a test filter, which only `swift test` turns into XCTest's
/// test names. Every mutant runs on the build the baseline made, so what holds for one run with no mutant on holds for
/// every mutant's: before the mutants, that run must pass and run as many XCTest and Swift Testing tests in each bundle
/// as the baseline did (`whyNot`).
struct DirectTestRun: Equatable, Sendable {
    /// What starts the bundles, which differs by platform. A case rather than `#if`, so either platform's script can be
    /// checked on the other.
    enum Platform: Equatable, Sendable {
        /// `helper` is `swiftpm-testing-helper`, in the toolchain of the test command's `swift`.
        /// `platformDeveloperFolder` is the macOS platform's `Developer` folder, whose frameworks the bundles load
        /// XCTest and Swift Testing from. `xctest` is Xcode's, which `swift test` runs XCTest tests with, from `xcrun
        /// --find xctest`; nil if `xcrun` found none, which only a run of XCTest tests needs.
        case macOS(helper: String, platformDeveloperFolder: String, xctest: String?)
        /// Each bundle is `<bundle>-test-runner`, which Swift Build makes for each test target, beside the `.so` that
        /// holds its tests.
        case linux
    }

    let platform: Platform
    /// The build's products folder, relative to the project, so each worker's clone runs its own build, unless
    /// `sharedBuild` names one for them all.
    let productsFolder: String
    /// The test bundles' names, in name order.
    let bundles: [String]
    /// The names of each bundle's test files, without `.swift`, from its test target's sources, for
    /// `bundles(forMutantIn:)`.
    let testFiles: [String: [String]]
    /// What follows `test` in a mutant's `swift test` command, `--skip-build` included. `swift test` passes its own
    /// arguments to each Swift Testing run, which reads the test filters among them and ignores the rest.
    var arguments: [String]
    /// The folder whose build, and whose copy of the project, every worker's runs use, when workers share one build
    /// rather than each have a clone (`sharingBuild(of:)`). Nil when each folder runs its own.
    var sharedBuild: URL?
    /// The names XCTest gave the bundles whose XCTest tests the baseline ran, without `.xctest`
    /// (`withXCTestBundles(ranIn:)`): on macOS, the bundles'; on Linux, where every runner's is the products folder's,
    /// that one name. Empty when the baseline ran no XCTest test, and a run then starts no XCTest run. Empty too when
    /// its log names no bundle's suite, as after a filtered baseline on Linux or one under `--parallel`, though it ran
    /// some (`baselineRanXCTest`).
    var xctestBundles: Set<String> = []
    /// Whether the baseline ran XCTest tests, whether or not its log says in which bundles
    /// (`withXCTestBundles(ranIn:)`), which `whyXCTestTestsNeedSwiftTest` checks before any check run.
    var baselineRanXCTest = false

    /// Why the bundles can't be run directly. A nil `reason` isn't worth telling: when `executable` isn't `swift`
    /// itself, as for a wrapper, say.
    struct Unavailable: Error, Equatable {
        let reason: String?
    }

    /// Whether a run starts XCTest runs: the baseline ran XCTest tests.
    var runsXCTest: Bool { !xctestBundles.isEmpty }

    /// Whether a run starts an XCTest run for `bundle`: on macOS if the baseline ran XCTest tests in it, on Linux,
    /// whose log doesn't say which runner ran which, if it ran any.
    func runsXCTest(in bundle: String) -> Bool {
        switch platform {
        case .macOS: xctestBundles.contains(bundle)
        case .linux: runsXCTest
        }
    }

    /// Whether each worker's tests have `UserDefaults` of their own: only a macOS run that starts no `xctest`, whose
    /// domain its embedded bundle identifier fixes, as every `swift test` run's is.
    var isolatesUserDefaults: Bool {
        guard case .macOS = platform else { return false }
        return !runsXCTest
    }

    /// This run with `more` given to each Swift Testing run after its own arguments, such as a test filter.
    func adding(_ more: [String]) -> Self {
        var copy = self
        copy.arguments += more
        return copy
    }

    /// This run with `filter`, test filter arguments, given to each Swift Testing run after its own, as `adding(_:)`
    /// does; nil when it runs XCTest tests, as only `swift test` turns a filter into XCTest's test names, so such a
    /// run goes through `swift test`.
    func filtered(by filter: [String]) -> Self? {
        runsXCTest ? nil : adding(filter)
    }

    /// This run with every worker's runs starting in `project`, on its build. What else is a worker's own goes by its
    /// folder's name, which then needs no folder: its active-mutant file, helper link, `UserDefaults`, activation
    /// markers and temporary folder.
    func sharingBuild(of project: URL) -> Self {
        var copy = self
        copy.sharedBuild = project
        return copy
    }

    /// The bundles in the order a mutant in `filePath` runs them: first those with a test file named after the mutated
    /// file, such as `FooTests.swift` or `FooParsingTests.swift` for `Foo.swift`, then the rest, each in name order. A
    /// run stopped at its first failed test or crash ends sooner when the bundle that kills the mutant comes first.
    /// Which bundles run, and so the verdict, don't change: only how long a killed mutant takes. With no `filePath`, as
    /// for a run with no mutant on, name order.
    func bundles(forMutantIn filePath: String?) -> [String] {
        guard let filePath else { return bundles }
        let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let first = bundles.filter { bundle in
            testFiles[bundle, default: []].contains { Self.isTestFile($0, of: name) }
        }
        return first + bundles.filter { !first.contains($0) }
    }

    /// Whether `testFile`, a test file's name without `.swift`, is named after the source file `name`: `name`, then
    /// more words or none, ending `Tests` or `Test`. `FormatterTests` isn't named after `Format`.
    static func isTestFile(_ testFile: String, of name: String) -> Bool {
        guard !name.isEmpty, testFile.hasPrefix(name), testFile.hasSuffix("Tests") || testFile.hasSuffix("Test") else {
            return false
        }
        return testFile.dropFirst(name.count).first?.isUppercase ?? false
    }

    /// The products folder that runs in `folder` use.
    func products(in folder: URL) -> String {
        (sharedBuild ?? folder).appendingPathComponent(productsFolder).path
    }

    /// The variables `swift test` sets for its test processes in `folder`: where the bundles find their frameworks and
    /// the package's dynamic libraries, and no colour. `script(in:)` sets them, on Linux with `LD_LIBRARY_PATH` before
    /// any the environment has.
    func environment(in folder: URL) -> [String: String] {
        let products = products(in: folder)
        switch platform {
        case let .macOS(_, platformDeveloperFolder, _):
            return [
                "DYLD_FRAMEWORK_PATH": [
                    "\(platformDeveloperFolder)/Library/Frameworks",
                    "\(platformDeveloperFolder)/Library/PrivateFrameworks",
                ].joined(separator: ":"),
                "DYLD_LIBRARY_PATH": "\(products):\(platformDeveloperFolder)/usr/lib",
                "NO_COLOR": "1",
            ]

        case .linux:
            return ["LD_LIBRARY_PATH": products, "NO_COLOR": "1"]
        }
    }
}
