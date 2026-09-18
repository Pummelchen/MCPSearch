import Foundation
import WebSearchCore

// MCPSMonitor — a mactop-style live dashboard for the MCP search server.
//
// Shows, at a glance, which search providers and which SearXNG nodes are up, which are
// answering and how fast, and which are returning errors. Providers are probed through
// the same adapters the server uses, so an error shown here is the error the server
// would produce.

// MARK: - Options

/// Owns the refresh loop and the mutable view state.
///
/// An actor because the loop touches counters and the model from both the refresh task
/// and the keyboard handler; keeping that state in one place is what makes the two safe
/// to run concurrently.
actor Monitor {
    private var options: Options
    private let log: Log
    private let http: any HTTPClient
    private let nodeProbe: NodeProbe
    private let providerProbe: ProviderProbe
    private var renderer: Renderer

    private var model: MonitorModel
    private var pinnedProbe = false
    private var refreshRequested = false
    /// Providers that have completed at least one probe.
    private var probedProviders: Set<ProviderID> = []

    init(options: Options) {
        let configuration = ProviderProbe.buildConfiguration()
        // A dedicated client: probing must not contend with anything else, and a short
        // timeout keeps a dead provider from stalling the whole refresh.
        var probeConfiguration = configuration
        probeConfiguration.requestTimeout = .seconds(8)
        let log = Log(level: .none)
        let http = URLSessionHTTPClient(configuration: probeConfiguration, log: log)
        self.init(
            options: options,
            configuration: configuration,
            http: http,
            log: log
        )
    }

    /// The same actor with its transport supplied.
    ///
    /// `refresh`'s probe gating, counter folding and warning aggregation cannot be reached
    /// from a test through `init(options:)`, which builds a live `URLSession` client and
    /// reads this machine's environment; a worker's shell has no nodes to probe and no keys
    /// to spend, so every refresh would return an unchanged model. This seam takes the
    /// transport and the configuration instead, so a test can script both. It is the same
    /// construction — a real `NodeProbe` and `ProviderProbe` over the supplied client — not
    /// a shortened test path.
    init(
        options: Options,
        configuration: AppConfiguration,
        http: any HTTPClient,
        log: Log
    ) {
        self.options = options
        self.log = log
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
        // no credentials must read as such rather than as ready to probe, and one the
        // operator disabled via SEARCH_DISABLED_PROVIDERS must read as switched off
        // rather than as ready.
        let providers = configuration.providerOrder
            .map { id in
                ProviderStatus.pending(
                    provider: id,
                    configured: providerProbe.isConfigured(id),
                    enabled: providerProbe.isEnabled(id),
                    hint: providerProbe.setupHint(for: id)
                )
            }
        self.model = MonitorModel(
            startedAt: Date(),
            refreshedAt: Date(),
            cycleDuration: .zero,
            nodes: options.nodes.map {
                NodeStatus.pending(
                    name: $0.name, endpoint: $0.baseURL.absoluteString, isLocal: $0.isLocal
                )
            },
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
        let providerIDs = providerProbe.probeableTargets()

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

        // This machine's own instance first, and separately: if it is down then the server
        // running here has lost its local provider, which is a different problem from a remote
        // node being unreachable, and the more urgent one to read.
        if let local = model.nodes.first(where: \.isLocal), local.state == .down {
            warnings.append(
                "this machine's SearXNG (\(local.name)) is down — the local server has no local provider"
            )
        }

        let downNodes = model.nodes.filter { $0.state == .down && !$0.isLocal }
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

// The loop used to fall off the end of the file, so the process exited 0 no matter what the
// probes found and `--iterations` could not be used as a health check. The
// status is derived here, after the summary, so a script always gets the prose first.
exit(options.exitCode(for: lastModel))
