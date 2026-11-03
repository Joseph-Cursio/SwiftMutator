@testable import muterCore
import XCTest

/// The fixture is `xcrun simctl list devices --json` from a Mac with Xcode 27.2, cut down to a few devices: an
/// iPhone 17 on iOS 26.5 and on 27.0, two devices named `swiftmutator-probe-twin` on iOS 26.5, one of them booted,
/// and one device each on tvOS, visionOS and a removed iOS 26.2, which simctl lists as unavailable.
final class SimulatorDestinationTests: XCTestCase {
    private let iPhone17Pro = "693E96A4-A11F-4223-B131-CFC50C9A17B8"
    private let iPhone17OniOS26 = "2287A7A0-7267-42D1-B831-27EAB2C17C5C"
    private let iPhone17OniOS27 = "2EC081DD-E2CB-44D4-97E6-6336BE58165D"
    private let bootedTwin = "461B8A08-7CE1-43BD-8F86-1812452225FB"
    private let appleTV = "DF42C8D1-A7B7-4BCF-BA74-9851D2792BF0"
    private let visionPro = "39440E5C-D840-4955-83D4-FA319A1F1CC9"
    private let unavailable = "5A1F3C0E-2B7D-4E8A-9C61-0D4B8E2F7A93"

    private lazy var list: SimctlDeviceList! = FileManager.default
        .contents(atPath: "\(fixturesDirectory)/Simctl/devices.json")
        .flatMap(SimctlDeviceList.init(json:))

    // MARK: - Reading a destination

    func test_readsThePlatformNameAndOS() {
        let destination = SimulatorDestination(destination: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5")

        XCTAssertEqual(fields(of: destination), ["iOS Simulator", nil, "iPhone 17 Pro", "26.5"])
    }

    func test_readsAnIdAlone() {
        let destination = SimulatorDestination(destination: "id=\(iPhone17Pro)")

        XCTAssertEqual(fields(of: destination), [nil, iPhone17Pro, nil, nil])
    }

    func test_ignoresSpacesAroundCommasAndEquals_andTheCaseOfKeys() {
        let destination = SimulatorDestination(
            destination: " platform = iOS Simulator, name=iPhone 17 Pro ,  os=latest, arch=arm64"
        )

        XCTAssertEqual(fields(of: destination), ["iOS Simulator", nil, "iPhone 17 Pro", "latest"])
    }

    func test_namesNoSimulator_forAMac_aDevice_anyDeviceOfAPlatform_orNoPlatformIdOrName() {
        for value in [
            "platform=macOS",
            "platform=macOS,arch=x86_64",
            "platform=macOS,variant=Mac Catalyst",
            "platform=iOS,id=00008110-001A2B3C4D5E801E",
            "generic/platform=iOS Simulator",
            "generic/platform=iOS",
            "arch=arm64",
            "",
        ] {
            XCTAssertNil(SimulatorDestination(destination: value), value)
        }
    }

    // MARK: - Finding its simulator

    func test_anId_findsThatDevice() {
        XCTAssertEqual(resolve("platform=iOS Simulator,id=\(iPhone17OniOS26)"), iPhone17OniOS26)
        XCTAssertEqual(resolve("id=\(iPhone17OniOS26.lowercased())"), iPhone17OniOS26)
    }

    func test_anId_winsOverAName() {
        XCTAssertEqual(resolve("platform=iOS Simulator,id=\(iPhone17OniOS26),name=Apple TV"), iPhone17OniOS26)
    }

    func test_anIdNotListed_orOfAnUnavailableDevice_findsNothing() {
        XCTAssertNil(resolve("id=00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(resolve("platform=iOS Simulator,id=\(unavailable)"))
    }

    func test_aNameAndOS_findTheDeviceOfThatNameOnThatVersion() {
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17,OS=26.5"), iPhone17OniOS26)
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17,OS=27.0"), iPhone17OniOS27)
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17,OS=27"), iPhone17OniOS27)
    }

    func test_aNameWithoutOS_orWithTheLatest_findsTheDeviceOnTheNewestRuntime() {
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17"), iPhone17OniOS27)
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17,OS=latest"), iPhone17OniOS27)
        XCTAssertEqual(resolve("name=iPhone 17"), iPhone17OniOS27)
    }

    // The fixture's unavailable device is an `iPhone 17 Pro` too, on the removed iOS 26.2.
    func test_aName_neverFindsAnUnavailableDevice() {
        XCTAssertEqual(resolve("platform=iOS Simulator,name=iPhone 17 Pro"), iPhone17Pro)
        XCTAssertNil(resolve("platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2"))
    }

    func test_aName_findsOnlyDevicesOfTheDestinationsPlatform() {
        XCTAssertEqual(resolve("platform=tvOS Simulator,name=Apple TV"), appleTV)
        XCTAssertEqual(resolve("platform=visionOS Simulator,name=Apple Vision Pro"), visionPro)
        XCTAssertNil(resolve("platform=iOS Simulator,name=Apple TV"))
        XCTAssertNil(resolve("platform=watchOS Simulator,name=Apple Vision Pro"))
    }

    func test_twoDevicesOfTheSameNameOnOneRuntime_findNothing() {
        XCTAssertNil(resolve("platform=iOS Simulator,name=swiftmutator-probe-twin"))
        XCTAssertNil(resolve("platform=iOS Simulator,name=swiftmutator-probe-twin,OS=26.5"))
    }

    func test_aNameNotListed_aVersionNotListed_orNoIdOrName_findNothing() {
        XCTAssertNil(resolve("platform=iOS Simulator,name=iPhone 4"))
        XCTAssertNil(resolve("platform=iOS Simulator,name=iPhone 17,OS=25.0"))
        XCTAssertNil(resolve("platform=iOS Simulator,name=iPhone 17,OS=newest"))
        XCTAssertNil(resolve("platform=iOS Simulator,OS=26.5"))
    }

    // MARK: - Reading simctl's list

    func test_readsEachDevice_withItsRuntime() throws {
        let list = try XCTUnwrap(list)

        XCTAssertEqual(list.devices.count, 9)
        XCTAssertEqual(list.devices.first { $0.udid == bootedTwin }, SimctlDevice(
            udid: bootedTwin,
            name: "swiftmutator-probe-twin",
            state: "Booted",
            isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        ))
        XCTAssertEqual(list.devices.filter { !$0.isShutdown }.map(\.udid), [bootedTwin])
        XCTAssertEqual(list.devices.filter { !$0.isAvailable }.map(\.udid), [unavailable])
    }

    func test_readsARuntimesPlatformAndVersion() {
        let runtime = SimctlRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        XCTAssertEqual(runtime?.platform, "iOS")
        XCTAssertEqual(runtime?.version, [26, 5])
        XCTAssertEqual(runtime?.destinationPlatform, "iOS Simulator")
        XCTAssertEqual(SimctlRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")?.version, [27])
        XCTAssertEqual(
            SimctlRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.xrOS-27-0")?.destinationPlatform,
            "visionOS Simulator"
        )
        XCTAssertNil(SimctlRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS"))
        XCTAssertNil(SimctlRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-beta-1"))
        XCTAssertNil(SimctlRuntime(identifier: "iOS-26-5"))
    }

    func test_readsAVersion_withoutItsTrailingZeros() {
        XCTAssertEqual(SimctlRuntime.version("26.5"), [26, 5])
        XCTAssertEqual(SimctlRuntime.version("27.0.0"), [27])
        XCTAssertEqual(SimctlRuntime.version("27.0.1"), [27, 0, 1])
        XCTAssertNil(SimctlRuntime.version("27."))
        XCTAssertNil(SimctlRuntime.version("latest"))
    }

    // A later Xcode may add, drop or retype a field: only the devices it touches are lost.
    func test_leavesOutADeviceItCantRead_andKeepsTheRest() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {"udid": "A", "name": "Kept", "state": "Shutdown", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "newField": {"x": 1}},
              {"udid": "B", "name": "No state", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
              {"udid": "C", "name": "Availability as text", "state": "Shutdown", "isAvailable": "YES",
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
              "not a device"
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": {"not": "a list"},
            "a runtime of another form": [
              {"udid": "D", "name": "Kept too", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18"}
            ]
          },
          "pairs": {}
        }
        """

        let list = try XCTUnwrap(SimctlDeviceList(json: Data(json.utf8)))

        XCTAssertEqual(list.devices.map(\.udid), ["D", "A"])
        XCTAssertNil(list.devices.first?.runtime)
        XCTAssertEqual(SimulatorDestination(destination: "id=D")?.resolve(in: list)?.name, "Kept too")
        XCTAssertNil(SimulatorDestination(destination: "name=Kept too")?.resolve(in: list))
    }

    func test_readsNoListWithoutADevicesObject() {
        XCTAssertNil(SimctlDeviceList(json: Data("{}".utf8)))
        XCTAssertNil(SimctlDeviceList(json: Data(#"{"devices": []}"#.utf8)))
        XCTAssertNil(SimctlDeviceList(json: Data("xcrun: error: unable to find utility \"simctl\"".utf8)))
        XCTAssertEqual(SimctlDeviceList(json: Data(#"{"devices": {}}"#.utf8))?.devices, [])
    }

    private func resolve(_ value: String) -> String? {
        SimulatorDestination(destination: value)?.resolve(in: list)?.udid
    }

    /// The destination's platform, id, name and OS, or nothing when there is no destination.
    private func fields(of destination: SimulatorDestination?) -> [String?] {
        destination.map { [$0.platform, $0.id, $0.name, $0.osVersion] } ?? []
    }
}
