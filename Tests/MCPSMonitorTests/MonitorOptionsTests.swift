import Foundation
import XCTest

@testable import MCPSMonitor


final class MonitorOptionsTests: XCTestCase {

    func testDefaultsIncludeTheClusterAndDoNotProbe() throws {
        let options = try Options.parse([])
        XCTAssertFalse(options.probeProviders, "probing spends credits, so it is opt-in")
        XCTAssertEqual(options.interval, .seconds(10))
        XCTAssertEqual(options.nodes.map(\.name).first, "this-mac")
        XCTAssertEqual(options.nodes.count, 5, "this machine plus four nodes")
    }

    func testDefaultNodesUseTailscaleAddresses() throws {
        let options = try Options.parse([])
        let addresses = options.nodes.map(\.baseURL.absoluteString)
        XCTAssertTrue(addresses.contains("http://127.0.0.1:8888"))
        for address in addresses.dropFirst() {
            XCTAssertTrue(
                address.contains(":8888"),
                "cluster nodes are reached over Tailscale on the SearXNG port: \(address)"
            )
        }
    }

    func testNoNodesDisablesNodeProbing() throws {
        XCTAssertTrue(try Options.parse(["--no-nodes"]).nodes.isEmpty)
    }

    func testCustomNodesReplaceTheDefaults() throws {
        let options = try Options.parse([
            "--node", "alpha=http://10.0.0.1:8888",
            "--node", "beta=http://10.0.0.2:9999",
        ])
        XCTAssertEqual(options.nodes.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(options.nodes[1].baseURL.absoluteString, "http://10.0.0.2:9999")
    }

    func testCustomNodeFlags() throws {
        let options = try Options.parse(["--node=gamma=http://10.0.0.3:8888"])
        XCTAssertEqual(options.nodes.map(\.name), ["gamma"])
    }

    func testProbeAndIntervalFlags() throws {
        let options = try Options.parse(["--probe", "--interval", "3"])
        XCTAssertTrue(options.probeProviders)
        XCTAssertEqual(options.interval, .seconds(3))
    }

    func testWatchIsAnAliasForProbe() throws {
        XCTAssertTrue(try Options.parse(["--watch"]).probeProviders)
    }

    func testIterationsAndToggles() throws {
        let options = try Options.parse(["--iterations", "4", "--no-colour", "--no-engines"])
        XCTAssertEqual(options.iterations, 4)
        XCTAssertFalse(options.useColour)
        XCTAssertFalse(options.showEngines)
    }

    func testInvalidArgumentsAreRejected() {
        for arguments in [
            ["--nonsense"],
            ["--interval", "0"],
            ["--interval", "abc"],
            ["--iterations", "0"],
            ["--node", "no-equals-sign"],
        ] {
            XCTAssertThrowsError(
                try Options.parse(arguments),
                "\(arguments) should be rejected rather than silently ignored"
            )
        }
    }

    func testHelpIsRequested() {
        XCTAssertThrowsError(try Options.parse(["--help"])) { error in
            guard case Options.OptionError.helpRequested = error else {
                return XCTFail("expected helpRequested, got \(error)")
            }
        }
    }

    func testUsageDocumentsEveryFlag() {
        for flag in ["--node", "--no-nodes", "--interval", "--probe", "--iterations",
                     "--no-colour", "--no-engines", "--help"] {
            XCTAssertTrue(Options.usage.contains(flag), "usage is missing \(flag)")
        }
    }
}
