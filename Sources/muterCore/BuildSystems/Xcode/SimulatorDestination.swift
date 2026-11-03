import Foundation

/// A `-destination` that names a simulator, read so the simulator it names can be found in simctl's list.
struct SimulatorDestination: Equatable, Sendable {
    /// The platform it names, such as `iOS Simulator`; nil when it names none, as an `id=` alone doesn't.
    let platform: String?
    /// The UDID it names.
    let id: String?
    /// The device name it names, such as `iPhone 17 Pro`.
    let name: String?
    /// The OS version it names, such as `26.5` or `latest`.
    let osVersion: String?

    /// The simulator destination `destination` names, an `xcodebuild -destination` value such as
    /// `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`. Nil when it names no simulator: another platform, such as
    /// `platform=macOS` or a device's `platform=iOS,id=…`, any device of a platform, `generic/platform=…`, or neither
    /// a platform, an id nor a name.
    init?(destination: String) {
        guard !destination.trimmed.hasPrefix("generic/") else {
            return nil
        }
        var values: [String: String] = [:]
        for pair in destination.split(separator: ",") {
            let keyAndValue = pair.split(separator: "=", maxSplits: 1)
            guard keyAndValue.count == 2 else {
                continue
            }
            values[String(keyAndValue[0]).trimmed.lowercased()] = String(keyAndValue[1]).trimmed
        }
        if let platform = values["platform"], !platform.hasSuffix(" Simulator") {
            return nil
        }
        guard values["platform"] != nil || values["id"] != nil || values["name"] != nil else {
            return nil
        }
        platform = values["platform"]
        id = values["id"]
        name = values["name"]
        osVersion = values["os"]
    }

    /// The available device in `list` that this destination names, or nil when it names none, or several of one name
    /// on one runtime.
    ///
    /// - An `id=` names that device, whatever else is given.
    /// - Otherwise a `name=` names the devices of that name whose runtime is of the destination's platform, if it names
    ///   one, and of the `OS=` version, or of the newest runtime among them without `OS=` or with `OS=latest`.
    func resolve(in list: SimctlDeviceList) -> SimctlDevice? {
        let available = list.devices.filter(\.isAvailable)
        if let id {
            return available.first { $0.udid.caseInsensitiveCompare(id) == .orderedSame }
        }
        guard let name else {
            return nil
        }
        let named = available.compactMap { device in
            device.runtime.flatMap { runtime in
                device.name == name && runsOnPlatform(runtime) ? (device: device, version: runtime.version) : nil
            }
        }
        let version: [Int]?
        if let osVersion, osVersion.lowercased() != "latest" {
            version = SimctlRuntime.version(osVersion)
        } else {
            version = named.map(\.version).max { $0.lexicographicallyPrecedes($1) }
        }
        let matching = named.filter { $0.version == version }.map(\.device)
        return matching.count == 1 ? matching.first : nil
    }

    /// Whether `runtime` is of the platform this destination names, or of any when it names none.
    private func runsOnPlatform(_ runtime: SimctlRuntime) -> Bool {
        platform.map { runtime.destinationPlatform.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }
}
