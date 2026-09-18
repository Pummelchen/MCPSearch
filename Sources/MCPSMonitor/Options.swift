import Foundation
import WebSearchCore

struct Options: Sendable {
    var nodes: [NodeProbe.Target]
    var interval: Duration
    var probeProviders: Bool
    var useColour: Bool
    var showEngines: Bool
    var iterations: Int?
    var probeQueries: ProbeQueries
    /// Permits probing more often than the safe floor.
    var allowExpensiveProbing = false
    /// Force exit status 0 whatever the probes found, for a purely graphical run.
    var exitZero = false
    /// Things the user should know about how their options were interpreted.
    var notes: [String] = []

    /// Shortest probe interval allowed without an explicit override.
    static let minimumProbeInterval = Duration.seconds(60)

    /// Longest refresh interval `--interval` accepts.
    ///
    /// A bound on arithmetic rather than a product decision: the value is converted to
    /// milliseconds with `Int(seconds * 1000)`, and `--interval inf` (or `1e30`) used to trap
    /// there before a single frame was drawn. A day is far longer than any real refresh, and it
    /// keeps that conversion inside `Int` for every accepted value.
    static let maximumInterval = Duration.seconds(24 * 60 * 60)

    /// Whether a refresh should probe providers.
    ///
    /// Probed on the first pass so the dashboard is populated immediately, then only when
    /// the operator presses `p` or runs with `--probe`. There is deliberately **no**
    /// periodic term: free mode is documented as costing nothing, and a keyed provider is
    /// billed for every probe, so an unattended dashboard must not spend credits. Extracted
    /// from the refresh loop so that guarantee is asserted by a test instead of being
    /// re-derived by reading the loop.
    static func shouldProbeProviders(
        probeRequested: Bool,
        forced: Bool,
        hasProbedBefore: Bool
    ) -> Bool {
        forced || probeRequested || !hasProbedBefore
    }

    /// The status a finished run reports to its caller.
    ///
    /// `--iterations` is documented as "useful for scripting", but the refresh loop fell off
    /// the end of `main.swift` and the process always exited 0, so a scripted run against a
    /// completely dead fleet was indistinguishable from a healthy one. The
    /// contract is deliberately a liveness check, not a per-node report:
    ///
    /// * `0` — the fleet answered: at least one probed node returned results and, if any
    ///   provider was configured, at least one of them was healthy. A run that checked
    ///   nothing (no nodes, no configured providers) is not a failed run.
    /// * `1` — every probed node failed to return results, or every configured provider
    ///   failed. A node that answered but returned nothing usable (`degraded`) counts as
    ///   failed: it cannot serve a search either.
    /// * `2` — the arguments were invalid, thrown during parsing before any probe.
    ///
    /// `--exit-zero` forces `0`: an operator watching the dashboard and an unattended script
    /// want different answers from the same run, and only the script asked for a status.
    func exitCode(for model: MonitorModel?) -> Int32 {
        // Checked before the model: a run that never completed a refresh has nothing to
        // report, and the flag is about the run rather than about its result.
        guard !exitZero, let model else { return 0 }

        let noNodeAnswered = !model.nodes.isEmpty && model.healthyNodes == 0

        // An unconfigured provider is an expected state (`NO KEY`), not a failure, and a
        // monitor with no keyed provider at all is not a failed health check. A provider the
        // operator switched off is expected too, so it does not count either.
        let configured = model.providers.filter(\.isInService)
        let noProviderWorked = !configured.isEmpty && model.healthyProviders == 0

        return noNodeAnswered || noProviderWorked ? 1 : 0
    }

    static let usage = """
        mcps-mon — live dashboard for MCPSearch providers and nodes.

        USAGE
          mcps-mon [options]

        OPTIONS
          --node <name=url>      Add a SearXNG node (repeatable). Defaults to this
                                 machine's own instance plus the cluster nodes. The
                                 local machine is not listed twice when it is also
                                 a cluster node.
          --no-nodes             Skip node probing entirely.
          --interval <seconds>   Refresh interval, 1 to 86400. Default 10.
          --probe                Also probe providers with a real search. This spends
                                 provider credits, so it is opt-in. The interval is
                                 raised to 60s while probing, because a keyed provider
                                 costs about one credit per probe.
          --watch                Alias for --probe.
          --allow-expensive-probing
                                 Permit probe intervals below 60s. A 10s interval costs
                                 roughly 360 credits an hour per keyed provider.
          --iterations <n>       Stop after n refreshes (useful for scripting).
          --exit-zero            Always exit 0, even when every node or every
                                 configured provider failed. For a purely graphical
                                 run; without it the status is a health check.
          --no-colour            Disable ANSI colour (--no-color is accepted too).
          --no-engines           Hide the per-node engine breakdown.
          --help                 Show this message.

        EXIT STATUS
          0  the fleet answered: a node returned results and, when any provider
             was configured, one of them was healthy (a run that probed nothing,
             or one that was told --exit-zero, also reports 0)
          1  every probed node failed, or every configured provider failed
          2  invalid arguments

        KEYS (interactive)
          p  probe providers now          r  refresh now
          e  toggle engine breakdown      c  toggle colour
          q  quit

        EXAMPLES
          mcps-mon                          # node health only, refreshes every 10s
          mcps-mon --probe                  # also measure provider latency and errors
          mcps-mon --node n1=http://100.66.125.48:8888
        """

    /// The cluster's SearXNG nodes, by Tailscale address.
    ///
    /// Addresses are Tailscale, so they work from anywhere the tailnet reaches, not only on the
    /// local network.
    ///
    /// `macbook-ab` is deliberately absent. It binds loopback only — it is a laptop, and a search
    /// instance should not follow it onto whatever network it joins next — so no other machine can
    /// probe it. It appears as *this* machine's local node when the monitor runs there.
    static let clusterNodes: [NodeProbe.Target] = [
        NodeProbe.Target(
            name: "node1", baseURL: URL(string: "http://100.66.125.48:8888")!, isLocal: false
        ),
        NodeProbe.Target(
            name: "node2", baseURL: URL(string: "http://100.97.158.87:8888")!, isLocal: false
        ),
        NodeProbe.Target(
            name: "node3", baseURL: URL(string: "http://100.114.69.128:8888")!, isLocal: false
        ),
        NodeProbe.Target(
            name: "node4", baseURL: URL(string: "http://100.80.144.76:8888")!, isLocal: false
        ),
    ]

    /// This machine's short hostname, lowercased to match the cluster names.
    static var localHostname: String {
        let short = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
        return (short ?? "this-mac").lowercased()
    }

    /// The fleet as it stands, used when no --node is supplied.
    ///
    /// The local instance is probed over loopback and named after the host, and the matching
    /// remote entry is then dropped, because it is the *same* instance. This list used to carry
    /// both — a loopback `this-mac` and the local machine's own Tailscale entry — which made a
    /// four-machine fleet report five nodes, and turned one node's failing engine into
    /// "unavailable on 2 node(s)": a fleet-level warning for a single machine.
    ///
    /// `localHostname` is a parameter so the rule can be asserted without depending on whichever
    /// host the tests happen to run on.
    static func defaultNodes(localHostname: String = Options.localHostname) -> [NodeProbe.Target] {
        var nodes = [
            NodeProbe.Target(
                name: localHostname,
                baseURL: URL(string: "http://127.0.0.1:8888")!,
                isLocal: true
            )
        ]
        nodes += clusterNodes.filter {
            $0.name.caseInsensitiveCompare(localHostname) != .orderedSame
        }
        return nodes
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(
            nodes: defaultNodes(),
            interval: Duration.seconds(10),
            probeProviders: false,
            useColour: Terminal.isInteractive,
            showEngines: true,
            iterations: nil,
            probeQueries: ProbeQueries()
        )
        var customNodes: [NodeProbe.Target] = []
        /// `--no-nodes` says "do not probe", so it must win over a `--node` list rather than
        /// depending on which came last. The two flags are order-independent in the usage text;
        /// before this, `--node n1=… --no-nodes` still probed n1.
        var nodesDisabled = false
        var index = 0

        func value(for flag: String) throws -> String {
            let current = arguments[index]
            if let equals = current.firstIndex(of: "=") {
                return String(current[current.index(after: equals)...])
            }
            guard index + 1 < arguments.count else { throw OptionError.missingValue(flag) }
            // A flag is not a value: `--node --interval=5` used to create a node literally named
            // `--interval` and swallow the interval flag.
            guard !arguments[index + 1].hasPrefix("--") else {
                throw OptionError.missingValue(flag)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch true {
            case argument == "--help" || argument == "-h":
                throw OptionError.helpRequested

            case argument == "--no-nodes":
                options.nodes = []
                nodesDisabled = true

            case argument == "--node" || argument.hasPrefix("--node="):
                let raw = try value(for: "--node")
                guard let separator = raw.firstIndex(of: "=") else {
                    throw OptionError.invalidValue(
                        flag: "--node", value: raw, expected: "name=url"
                    )
                }
                let name = String(raw[raw.startIndex..<separator])
                let urlText = String(raw[raw.index(after: separator)...])
                // `URL(string:)` accepts a relative reference, so `n1=foo` used to start and then
                // show `n1 DOWN … unreachable` instead of failing here; a node needs an absolute
                // URL, which means a scheme and a host.
                guard let url = URL(string: urlText), url.scheme != nil, url.host() != nil else {
                    throw OptionError.invalidValue(
                        flag: "--node", value: raw, expected: "name=absolute-url"
                    )
                }
                customNodes.append(
                    NodeProbe.Target(name: name, baseURL: url, isLocal: urlText.contains("127.0.0.1"))
                )

            case argument == "--interval" || argument.hasPrefix("--interval="):
                let raw = try value(for: "--interval")
                // `isFinite` is the part that matters: `Double("inf")` parses, satisfies
                // `>= 1`, and would trap in the conversion below.
                guard let seconds = Double(raw), seconds.isFinite,
                    seconds >= 1, seconds <= Options.maximumInterval.seconds
                else {
                    throw OptionError.invalidValue(
                        flag: "--interval", value: raw,
                        expected: "seconds between 1 and \(Int(Options.maximumInterval.seconds))"
                    )
                }
                options.interval = Duration.milliseconds(Int(seconds * 1000))

            case argument == "--iterations" || argument.hasPrefix("--iterations="):
                let raw = try value(for: "--iterations")
                guard let count = Int(raw), count > 0 else {
                    throw OptionError.invalidValue(
                        flag: "--iterations", value: raw, expected: "a positive integer"
                    )
                }
                options.iterations = count

            case argument == "--probe" || argument == "--watch":
                options.probeProviders = true

            case argument == "--allow-expensive-probing":
                options.allowExpensiveProbing = true

            case argument == "--exit-zero":
                options.exitZero = true

            case argument == "--no-colour" || argument == "--no-color":
                options.useColour = false

            case argument == "--no-engines":
                options.showEngines = false

            default:
                throw OptionError.unknownArgument(argument)
            }
            index += 1
        }

        if nodesDisabled {
            if !customNodes.isEmpty {
                options.notes.append("--no-nodes overrides the --node list; no node is probed")
            }
            options.nodes = []
        } else if !customNodes.isEmpty {
            options.nodes = customNodes
        }

        // Continuous provider probing spends real credits. A basic Tavily search costs
        // one credit, so at the default 10s interval a single keyed provider would burn
        // roughly 360 credits an hour and exhaust a 1000-credit month in under three.
        // Rather than silently doing that, require an explicit opt-in below the floor.
        if options.probeProviders, !options.allowExpensiveProbing {
            let floor = Options.minimumProbeInterval
            if options.interval < floor {
                options.interval = floor
                options.notes.append(
                    "probe interval raised to \(Int(floor.seconds))s to protect provider "
                        + "credits; pass --allow-expensive-probing to override"
                )
            }
        }
        return options
    }

    enum OptionError: Error, CustomStringConvertible {
        case helpRequested
        case unknownArgument(String)
        case missingValue(String)
        case invalidValue(flag: String, value: String, expected: String)

        var description: String {
            switch self {
            case .helpRequested: ""
            case .unknownArgument(let argument): "Unknown argument: \(argument)"
            case .missingValue(let flag): "Missing value for \(flag)"
            case .invalidValue(let flag, let value, let expected):
                "Invalid value for \(flag): '\(value)' (expected \(expected))"
            }
        }
    }
}

// MARK: - Monitor
