import Foundation

/// The simulators `xcrun simctl list devices --json` lists, under the runtime each runs.
///
/// Read so that what another Xcode adds, drops or renames costs only the devices it touches: fields the list doesn't
/// know are ignored, and a device that lacks one it needs, or holds one of another type, is left out rather than
/// failing the whole list.
struct SimctlDeviceList: Equatable, Sendable {
    /// Each device listed, by its runtime's identifier and then in simctl's order.
    let devices: [SimctlDevice]

    init(devices: [SimctlDevice]) {
        self.devices = devices
    }

    /// The devices in `json`, simctl's output, or nil if it isn't JSON with a `devices` object of runtimes.
    init?(json: Data) {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: json) else {
            return nil
        }
        devices = listing.devices.keys.sorted().flatMap { runtimeIdentifier in
            (listing.devices[runtimeIdentifier]?.value ?? []).compactMap { entry in
                entry.value.map { SimctlDevice($0, runtimeIdentifier: runtimeIdentifier) }
            }
        }
    }

    /// simctl's output: `{"devices": {"<runtime identifier>": [<device>, …], …}}`.
    private struct Listing: Decodable {
        let devices: [String: Lossy<[Lossy<Entry>]>]
    }

    /// A device as simctl lists it, with the fields SwiftMutator reads.
    fileprivate struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String
    }

    /// A value, or nil where the JSON holds something that doesn't decode as one.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

/// A simulator as `simctl list devices --json` lists it.
struct SimctlDevice: Equatable, Sendable {
    let udid: String
    let name: String
    /// What it's doing: `Shutdown`, `Booted`, `Shutting Down`, and so on.
    let state: String
    /// False when simctl can't run it, as when its runtime was removed.
    let isAvailable: Bool
    /// What kind of device it is, as `simctl create` takes it: `com.apple.CoreSimulator.SimDeviceType.iPhone-17`.
    let deviceTypeIdentifier: String
    /// The runtime it runs, as `simctl create` takes it: `com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
    let runtimeIdentifier: String

    init(
        udid: String,
        name: String,
        state: String,
        isAvailable: Bool,
        deviceTypeIdentifier: String,
        runtimeIdentifier: String
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
    }

    fileprivate init(_ entry: SimctlDeviceList.Entry, runtimeIdentifier: String) {
        self.init(
            udid: entry.udid,
            name: entry.name,
            state: entry.state,
            isAvailable: entry.isAvailable,
            deviceTypeIdentifier: entry.deviceTypeIdentifier,
            runtimeIdentifier: runtimeIdentifier
        )
    }

    /// Whether it's shut down, the only state in which `simctl clone` copies it.
    var isShutdown: Bool { state == "Shutdown" }

    /// Its runtime's platform and version, or nil when the runtime's identifier doesn't name them.
    var runtime: SimctlRuntime? { SimctlRuntime(identifier: runtimeIdentifier) }
}

/// A simulator runtime's platform and version, as its identifier names them: `iOS` and 26.5 for
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
struct SimctlRuntime: Equatable, Sendable {
    /// The platform as runtimes name it: `iOS`, `tvOS`, `watchOS`, or `xrOS` for visionOS.
    let platform: String
    /// The version's numbers without trailing zeros, so that 27, 27.0 and 27.0.0 are the same, [27], and the newer of
    /// two versions is the one that comes later in lexicographic order.
    let version: [Int]

    init?(identifier: String) {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else {
            return nil
        }
        let parts = identifier.dropFirst(prefix.count).split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let version = Self.version(String(parts[1]), separatedBy: "-")
        else {
            return nil
        }
        platform = String(parts[0])
        self.version = version
    }

    /// The platform a `-destination` names for a simulator of this runtime: `iOS Simulator`, or `visionOS Simulator`
    /// for `xrOS`.
    var destinationPlatform: String {
        (platform == "xrOS" ? "visionOS" : platform) + " Simulator"
    }

    /// The numbers of `text`, a version such as `26.5`, without trailing zeros; nil if any part isn't a number.
    static func version(_ text: String, separatedBy separator: Character = ".") -> [Int]? {
        let numbers = text.split(separator: separator, omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return Array(numbers.compactMap(\.self).reversed().drop { $0 == 0 }.reversed())
    }
}
