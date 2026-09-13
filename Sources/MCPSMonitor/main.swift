import Foundation
import WebSearchCore

// MCPSMonitor — a mactop-style live dashboard for the MCP search server.
//
// Shows, at a glance, which search providers and which SearXNG nodes are up, which are
// answering and how fast, and which are returning errors. Providers are probed through
// the same adapters the server uses, so an error shown here is the error the server
// would produce.

// MARK: - Options

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

    static let usage = """
        mcps-mon — live dashboard for MCPSearch providers and nodes.

        USAGE
          mcps-mon [options]

        OPTIONS
          --node <name=url>      Add a SearXNG node (repeatable). Defaults to this
                                 machine plus the cluster nodes if reachable.
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
          --no-colour            Disable ANSI colour (--no-color is accepted too).
          --no-engines           Hide the per-node engine breakdown.
          --help                 Show this message.

        KEYS (interactive)
          p  probe providers now          r  refresh now
          e  toggle engine breakdown      c  toggle colour
          q  quit

        EXAMPLES
          mcps-mon                          # node health only, refreshes every 10s
          mcps-mon --probe                  # also measure provider latency and errors
          mcps-mon --node n1=http://100.66.125.48:8888
        """

    /// The cluster as it stands, used when no --node is supplied.
    ///
    /// Addresses are Tailscale, so they work from anywhere the tailnet reaches, not only
    /// on the local network.
    static var defaultNodes: [NodeProbe.Target] {
        [
            NodeProbe.Target(
                name: "this-mac",
                baseURL: URL(string: "http://127.0.0.1:8888")!,
                isLocal: true
            ),
            NodeProbe.Target(
                name: "node1",
                baseURL: URL(string: "http://100.66.125.48:8888")!,
                isLocal: false
            ),
            NodeProbe.Target(
                name: "node2",
                baseURL: URL(string: "http://100.97.158.87:8888")!,
                isLocal: false
            ),
            NodeProbe.Target(
                name: "node3",
                baseURL: URL(string: "http://100.114.69.128:8888")!,
                isLocal: false
            ),
            NodeProbe.Target(
                name: "node4",
                baseURL: URL(string: "http://100.80.144.76:8888")!,
                isLocal: false
            ),
        ]
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(
            nodes: defaultNodes,
            interval: Duration.seconds(10),
            probeProviders: false,
            useColour: Terminal.isInteractive,
            showEngines: true,
            iterations: nil,
            probeQueries: ProbeQueries()
        )
        var customNodes: [NodeProbe.Target] = []
        var index = 0

        func value(for flag: String) throws -> String {
            let current = arguments[index]
            if let equals = current.firstIndex(of: "=") {
                return String(current[current.index(after: equals)...])
            }
            guard index + 1 < arguments.count else { throw OptionError.missingValue(flag) }
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

            case argument == "--node" || argument.hasPrefix("--node="):
                let raw = try value(for: "--node")
                guard let separator = raw.firstIndex(of: "=") else {
                    throw OptionError.invalidValue(
                        flag: "--node", value: raw, expected: "name=url"
                    )
                }
                let name = String(raw[raw.startIndex..<separator])
                let urlText = String(raw[raw.index(after: separator)...])
                guard let url = URL(string: urlText) else {
                    throw OptionError.invalidValue(
                        flag: "--node", value: raw, expected: "name=url"
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

            case argument == "--no-colour" || argument == "--no-color":
                options.useColour = false

            case argument == "--no-engines":
                options.showEngines = false

            default:
                throw OptionError.unknownArgument(argument)
            }
            index += 1
        }

        if !customNodes.isEmpty { options.nodes = customNodes }

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

/// Owns the refresh loop and the mutable view state.
///
/// An actor because the loop touches counters and the model from both the refresh task
/// and the keyboard handler; keeping that state in one place is what makes the two safe
/// to run concurrently.
actor Monitor {
    private var options: Options
    private let log = Log(level: .none)
    private let http: URLSessionHTTPClient
    private let nodeProbe: NodeProbe
    private let providerProbe: ProviderProbe
    private var renderer: Renderer

    private var model: MonitorModel
    private var pinnedProbe = false
    private var refreshRequested = false
    /// Providers that have completed at least one probe.
    private var probedProviders: Set<ProviderID> = []

    init(options: Options) {
        self.options = options

        let configuration = ProviderProbe.buildConfiguration()
        // A dedicated client: probing must not contend with anything else, and a short
        // timeout keeps a dead provider from stalling the whole refresh.
        var probeConfiguration = configuration
        probeConfiguration.requestTimeout = .seconds(8)
        let http = URLSessionHTTPClient(configuration: probeConfiguration, log: log)
        self.http = http
        self.nodeProbe = NodeProbe(http: http)
        let providerProbe = ProviderProbe(
            registry: ProviderProbe.buildRegistry(
                configuration: configuration,
                http: http,
                log: log
            ),
            configuration: configuration,
            log: log
        )
        self.providerProbe = providerProbe
        self.renderer = Renderer(
            useColour: options.useColour,
            showEngines: options.showEngines
        )

        // Start with every provider visible but unprobed, so the first frame already
        // shows what is configured rather than an empty table. Configured state comes
        // from the registry, not from the provider merely being listed: a provider with
        // no credentials must read as such rather than as ready to probe.
        let providers = configuration.providerOrder
            .map { id in
                ProviderStatus.pending(
                    provider: id,
                    configured: providerProbe.isConfigured(id),
                    hint: providerProbe.setupHint(for: id)
                )
            }
        self.model = MonitorModel(
            startedAt: Date(),
            refreshedAt: Date(),
            cycleDuration: .zero,
            nodes: options.nodes.map { NodeStatus.pending(name: $0.name, endpoint: $0.baseURL.absoluteString) },
            providers: providers,
            warnings: []
        )
    }

    var coloursEnabled: Bool { renderer.useColour }
    var enginesShown: Bool { renderer.showEngines }

    func toggleColour() { renderer.useColour.toggle() }
    func toggleEngines() { renderer.showEngines.toggle() }
    func requestProbe() { pinnedProbe = true }
    func consumeProbeRequest() -> Bool {
        defer { pinnedProbe = false }
        return pinnedProbe
    }

    /// Ask the loop to refresh immediately instead of waiting out the interval.
    func requestRefresh() { refreshRequested = true }

    /// Sleep in short slices so a key press is noticed promptly, and return early when
    /// the operator asks for a refresh.
    func waitForNextCycle(_ interval: Duration) async {
        let deadline = Date().addingTimeInterval(interval.seconds)
        while Date() < deadline {
            if refreshRequested {
                refreshRequested = false
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Run one refresh and return the model to draw.
    ///
    /// Nodes and providers are probed concurrently: a slow provider must not delay the
    /// node column, and vice versa.
    func refresh(forceProbeProviders: Bool) async -> MonitorModel {
        let started = DispatchTime.now().uptimeNanoseconds

        let shouldProbeProviders = Options.shouldProbeProviders(
            probeRequested: options.probeProviders,
            forced: forceProbeProviders,
            hasProbedBefore: !probedProviders.isEmpty
        )

        let query = options.probeQueries.next()
        let nodeTargets = options.nodes
        let providerIDs = providerProbe.probeTargets().filter { providerProbe.isConfigured($0) }

        async let nodes = probeNodes(nodeTargets)
        async let providers =
            shouldProbeProviders
            ? probeProviders(providerIDs, query: query)
            : []

        let nodeResults = await nodes
        let providerResults = await providers

        var updated = model
        updated.refreshedAt = Date()
        for (name, result) in nodeResults {
            if let index = updated.nodes.firstIndex(where: { $0.name == name }) {
                updated.nodes[index] = updated.nodes[index].applying(result)
            }
        }
        for (id, outcome) in providerResults {
            probedProviders.insert(id)
            if let index = updated.providers.firstIndex(where: { $0.provider == id }) {
                updated.providers[index] = updated.providers[index].applying(outcome)
            }
        }

        updated.cycleDuration = .milliseconds(
            Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        )
        updated.warnings = buildWarnings(updated)
        model = updated
        return updated
    }

    private func probeNodes(_ targets: [NodeProbe.Target]) async -> [(String, NodeProbe.Result)] {
        guard !targets.isEmpty else { return [] }
        return await withTaskGroup(of: (String, NodeProbe.Result).self) { group in
            for target in targets {
                group.addTask { [nodeProbe] in
                    (target.name, await nodeProbe.probe(target))
                }
            }
            var collected: [(String, NodeProbe.Result)] = []
            for await item in group { collected.append(item) }
            return collected
        }
    }

    private func probeProviders(
        _ ids: [ProviderID],
        query: String
    ) async -> [(ProviderID, ProbeOutcome)] {
        guard !ids.isEmpty else { return [] }
        return await withTaskGroup(of: (ProviderID, ProbeOutcome).self) { group in
            for id in ids {
                group.addTask { [providerProbe] in
                    (id, await providerProbe.probe(id, query: query))
                }
            }
            var collected: [(ProviderID, ProbeOutcome)] = []
            for await item in group { collected.append(item) }
            return collected
        }
    }

    /// Surface conditions an operator should act on rather than hunt for.
    private func buildWarnings(_ model: MonitorModel) -> [String] {
        var warnings: [String] = []

        let downNodes = model.nodes.filter { $0.state == .down }
        if !downNodes.isEmpty {
            warnings.append(
                "\(downNodes.count) node(s) unreachable: "
                    + downNodes.map(\.name).joined(separator: ", ")
            )
        }

        // Engines failing on every node is a provider-level problem, not a node problem,
        // and is the single most useful thing to call out.
        let failingEngines = model.nodes
            .flatMap(\.unavailableEngines)
            .compactMap { $0.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) } }
        let counts = Dictionary(grouping: failingEngines, by: { $0 }).mapValues(\.count)
        for (engine, count) in counts.sorted(by: { $0.value > $1.value })
        where count >= max(2, model.nodes.count / 2) {
            warnings.append("engine '\(engine)' unavailable on \(count) node(s)")
        }

        let withoutCredentials = model.providers.filter { $0.state == .notConfigured }
        if !withoutCredentials.isEmpty {
            warnings.append(
                "\(withoutCredentials.count) provider(s) have no credentials; "
                    + "press p to probe the rest"
            )
        }
        return warnings
    }
}

// MARK: - Entry point

/// Draw one frame.
func draw(_ model: MonitorModel, renderer: Renderer) {
    let size = Terminal.size
    let lines = renderer.render(model, columns: size.columns, rows: size.rows)

    var output = Terminal.home()
    for (index, line) in lines.enumerated() {
        output += line + Terminal.clearToEndOfLine
        if index < lines.count - 1 { output += "\r\n" }
    }
    output += Terminal.clearToEndOfScreen
    FileHandle.standardOutput.write(Data(output.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let options: Options
do {
    options = try Options.parse(arguments)
} catch Options.OptionError.helpRequested {
    print(Options.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("mcps-mon: \(error)\n\n".utf8))
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}

for note in options.notes {
    FileHandle.standardError.write(Data("mcps-mon: \(note)\n".utf8))
}

let monitor = Monitor(options: options)
let interactive = Terminal.isInteractive

// Non-interactive runs (piped to a file, or in CI) must not emit cursor escapes: they
// render a plain frame per refresh instead, so the output stays readable.
if interactive {
    FileHandle.standardOutput.write(Data((Terminal.hideCursor + Terminal.clearScreen).utf8))
}

// Keyboard handling runs alongside the refresh loop. It only mutates small flags on the
// actor, so it never blocks a refresh.
/// Shared run flag.
///
/// The keyboard handler runs in its own task while the refresh loop runs on the main
/// actor, so the flag lives in an actor rather than in a captured `var`.
actor RunFlag {
    private var running = true
    var isRunning: Bool { running }
    func stop() { running = false }
}

let keyReader = interactive ? KeyReader() : nil
let runFlag = RunFlag()

func installKeyHandler(_ reader: KeyReader, monitor: Monitor, flag: RunFlag) {
    Task {
        while await flag.isRunning {
            try? await Task.sleep(for: .milliseconds(80))
            while let byte = reader.readByte() {
                switch Character(UnicodeScalar(byte)) {
                case "q", "Q", "\u{03}":  // q or Ctrl-C
                    await flag.stop()
                case "p", "P":
                    await monitor.requestProbe()
                case "r", "R":
                    await monitor.requestRefresh()
                case "e", "E":
                    await monitor.toggleEngines()
                case "c", "C":
                    await monitor.toggleColour()
                default:
                    break
                }
            }
        }
    }
}

if let keyReader {
    installKeyHandler(keyReader, monitor: monitor, flag: runFlag)
}

var iteration = 0
var lastModel: MonitorModel?

while await runFlag.isRunning {
    if let limit = options.iterations, iteration >= limit { break }

    let forced = await monitor.consumeProbeRequest()
    let model = await monitor.refresh(forceProbeProviders: forced)
    lastModel = model
    iteration += 1

    let renderer = Renderer(
        useColour: await monitor.coloursEnabled,
        showEngines: await monitor.enginesShown
    )

    if interactive {
        draw(model, renderer: renderer)
    } else {
        // Plain-text frame for logs and piping. `fillHeight: false` because there is no
        // screen to fill: padding to an assumed height looks like a stray block of blank
        // lines in a file, and capping the sections to it could silently drop providers.
        let size = Terminal.size
        let frame = renderer.render(
            model,
            columns: size.columns,
            rows: size.rows,
            fillHeight: false
        )
        print(frame.joined(separator: "\n"))
        print("")
    }

    if let limit = options.iterations, iteration >= limit { break }
    if !interactive && options.iterations == nil { break }

    // Sleep in short slices so a key press is noticed promptly, `r` takes effect at
    // once, and quitting is immediate.
    await monitor.waitForNextCycle(options.interval)
}

if interactive {
    FileHandle.standardOutput.write(Data((Terminal.showCursor + Terminal.clearToEndOfScreen).utf8))
}
keyReader?.restore()

// A final plain summary, so the tail of a run still contains the numbers even after the
// live display is gone.
if let model = lastModel {
    print("")
    print("final: \(model.healthyProviders) provider(s) ok, \(model.healthyNodes)/\(model.nodes.count) node(s) up")
}
