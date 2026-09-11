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
        // An interval above the probe floor, so the cost guard does not adjust it.
        let options = try Options.parse(["--probe", "--interval", "90"])
        XCTAssertTrue(options.probeProviders)
        XCTAssertEqual(options.interval, .seconds(90))
        XCTAssertTrue(options.notes.isEmpty)
    }

    /// Continuous provider probing spends real credits, so a fast interval must not be
    /// accepted silently. At 10s a keyed provider costs ~360 credits an hour, which
    /// exhausts a 1000-credit month in under three hours.
    func testFastProbeIntervalIsRaisedAndReported() throws {
        let options = try Options.parse(["--probe", "--interval", "5"])
        XCTAssertEqual(options.interval, Options.minimumProbeInterval)
        XCTAssertEqual(options.notes.count, 1, "the adjustment must be reported, not silent")
        XCTAssertTrue(
            options.notes[0].contains("--allow-expensive-probing"),
            "the note should say how to override: \(options.notes[0])"
        )
    }

    /// A deliberately slow interval is left exactly as asked for.
    func testSlowProbeIntervalIsNotAdjusted() throws {
        let options = try Options.parse(["--probe", "--interval", "120"])
        XCTAssertEqual(options.interval, .seconds(120))
        XCTAssertTrue(options.notes.isEmpty)
    }

    /// Without probing, a fast refresh only costs local CPU, so it is allowed.
    func testFastIntervalIsFineWithoutProbing() throws {
        let options = try Options.parse(["--interval", "2"])
        XCTAssertEqual(options.interval, .seconds(2))
        XCTAssertTrue(options.notes.isEmpty)
    }

    func testExplicitOverridePermitsFastProbing() throws {
        let options = try Options.parse([
            "--probe", "--interval", "5", "--allow-expensive-probing",
        ])
        XCTAssertEqual(options.interval, .seconds(5))
        XCTAssertTrue(options.notes.isEmpty, "an explicit override should not warn")
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
