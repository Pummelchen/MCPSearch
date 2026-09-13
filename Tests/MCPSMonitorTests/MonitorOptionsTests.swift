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

    /// The defaults are this deployment's Tailscale addresses, pinned exactly.
    ///
    /// The previous assertion only checked `contains(":8888")`, so a stale or mistyped node
    /// address would have gone unnoticed while the dashboard quietly reported a missing
    /// node. These are the addresses the wiki documents; change both together.
    func testDefaultNodesAreTheDocumentedAddresses() throws {
        let options = try Options.parse([])
        XCTAssertEqual(
            options.nodes.map { "\($0.name)=\($0.baseURL.absoluteString)" },
            [
                "this-mac=http://127.0.0.1:8888",
                "node1=http://100.66.125.48:8888",
                "node2=http://100.97.158.87:8888",
                "node3=http://100.114.69.128:8888",
                "node4=http://100.80.144.76:8888",
            ]
        )
    }

    func testNoNodesDisablesNodeProbing() throws {
        XCTAssertTrue(try Options.parse(["--no-nodes"]).nodes.isEmpty)
    }

    /// `--no-nodes` must win whichever order it appears in.
    ///
    /// It sets an empty node list inside the parse loop, and the custom `--node` list was applied
    /// unconditionally after the loop, so `--node n1=… --no-nodes` still probed n1 while
    /// `--no-nodes --node n1=…` probably did too — the flags were order-independent in the usage
    /// text and order-dependent in the code (ledger B74).
    func testNoNodesOverridesACustomNodeListInEitherOrder() throws {
        for arguments in [
            ["--node", "stub=http://127.0.0.1:8888", "--no-nodes"],
            ["--no-nodes", "--node", "stub=http://127.0.0.1:8888"],
        ] {
            let options = try Options.parse(arguments)
            XCTAssertTrue(
                options.nodes.isEmpty,
                "\(arguments) must probe nothing, got \(options.nodes.map(\.name))"
            )
        }
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

    /// A flag is not a value, and a node needs an absolute URL.
    ///
    /// `--node --interval=5` used to create a node named `--interval` and swallow the interval
    /// flag, and `n1=relative/path` used to start and then report the node as unreachable instead
    /// of failing at parse time (ledger B75).
    func testFlagsAreNotValuesAndNodesNeedAbsoluteURLs() {
        for arguments in [
            ["--node", "--interval=5"],
            ["--interval", "--node", "n1=http://127.0.0.1:8888"],
            ["--node", "n1=relative/path"],
            ["--node", "n1="],
        ] {
            XCTAssertThrowsError(
                try Options.parse(arguments),
                "\(arguments) must be rejected"
            )
        }
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
        for flag in [
            "--node", "--no-nodes", "--interval", "--probe", "--watch",
            "--allow-expensive-probing", "--iterations", "--no-colour",
            "--no-color", "--no-engines", "--help",
        ] {
            XCTAssertTrue(Options.usage.contains(flag), "usage is missing \(flag)")
        }
    }

    /// Free mode must cost nothing: a refresh nobody asked for must not probe providers.
    ///
    /// The refresh loop used to carry an unconditional `cycle % 6 == 0` term, so an
    /// unattended dashboard issued a real search roughly once a minute per keyed provider
    /// while the README, the wiki and this tool's own option text all described that mode
    /// as free. The decision now lives here so a regression fails a test.
    func testProvidersAreOnlyProbedWhenAsked() {
        XCTAssertFalse(
            Options.shouldProbeProviders(
                probeRequested: false, forced: false, hasProbedBefore: true
            ),
            "an unattended refresh must not spend provider credits"
        )
        XCTAssertTrue(
            Options.shouldProbeProviders(
                probeRequested: false, forced: false, hasProbedBefore: false
            ),
            "the first pass populates the dashboard"
        )
        XCTAssertTrue(
            Options.shouldProbeProviders(
                probeRequested: true, forced: false, hasProbedBefore: true
            ),
            "--probe asks for continuous probing"
        )
        XCTAssertTrue(
            Options.shouldProbeProviders(
                probeRequested: false, forced: true, hasProbedBefore: true
            ),
            "the p key asks for one probe"
        )
    }

    /// `--interval` is converted to milliseconds with `Int(seconds * 1000)`, and the value comes
    /// straight from the command line. `inf` parsed, passed the `>= 1` check and trapped the
    /// process before the first frame; `1e30` did the same (ledger B06, reported as L3-3).
    func testHostileIntervalsAreRejectedInsteadOfTrapping() {
        let hostile = ["inf", "-inf", "infinity", "1e30", "nan", "0", "-5", "0.5", "99999999999999999999"]
        for raw in hostile {
            XCTAssertThrowsError(try Options.parse(["--interval", raw]), "\(raw) must be rejected") { error in
                guard case Options.OptionError.invalidValue(let flag, _, let expected) = error else {
                    return XCTFail("expected invalidValue for \(raw), got \(error)")
                }
                XCTAssertEqual(flag, "--interval")
                XCTAssertTrue(expected.contains("86400"), expected)
            }
        }
    }

    func testTheLongestAcceptedIntervalIsTheDocumentedMaximum() throws {
        let maximum = Int(Options.maximumInterval.seconds)
        XCTAssertEqual(maximum, 86_400)
        XCTAssertEqual(
            try Options.parse(["--interval", "\(maximum)"]).interval.seconds,
            Double(maximum)
        )
        XCTAssertThrowsError(try Options.parse(["--interval", "\(maximum + 1)"]))
        // A whole-number value still works exactly as before.
        XCTAssertEqual(try Options.parse(["--interval", "45"]).interval, .seconds(45))
    }
}
