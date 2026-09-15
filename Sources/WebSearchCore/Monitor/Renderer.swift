import Foundation

/// Draws the dashboard.
///
/// Rendering is pure: it takes a model and returns the lines to display. That keeps the
/// layout testable and means the refresh loop has no drawing logic of its own.
///
/// Everything a probe or an error body contributed — node names, engine names, error strings,
/// warnings — is passed through `Terminal.sanitize` before it is styled or padded. Styling is
/// applied afterwards, so the dashboard's own escape sequences survive. This is the single
/// boundary that turns untrusted text into terminal output (ledger B25).
public struct Renderer: Sendable {
    public var useColour: Bool
    public var showEngines: Bool

    public init(useColour: Bool = true, showEngines: Bool = true) {
        self.useColour = useColour
        self.showEngines = showEngines
    }

    // MARK: - Status glyphs

    /// A single character per state, so the eye can scan the left column.
    private func glyph(_ state: NodeStatus.State) -> String {
        switch state {
        case .up: Terminal.colour("●", .brightGreen, enabled: useColour)
        case .degraded: Terminal.colour("◐", .brightYellow, enabled: useColour)
        case .down: Terminal.colour("○", .brightRed, enabled: useColour)
        case .checking: Terminal.colour("·", .grey, enabled: useColour)
        }
    }

    private func glyph(_ state: ProviderStatus.State) -> String {
        switch state {
        case .healthy: Terminal.colour("●", .brightGreen, enabled: useColour)
        case .configuredButIdle: Terminal.colour("○", .cyan, enabled: useColour)
        case .failing: Terminal.colour("✖", .brightRed, enabled: useColour)
        case .notConfigured: Terminal.colour("–", .grey, enabled: useColour)
        case .unavailable: Terminal.colour("◐", .brightYellow, enabled: useColour)
        }
    }

    private func stateText(_ state: ProviderStatus.State) -> String {
        let label = Terminal.pad(state.label, to: 6)
        switch state {
        case .healthy: return Terminal.colour(label, .brightGreen, enabled: useColour)
        case .failing: return Terminal.colour(label, .brightRed, enabled: useColour)
        case .notConfigured: return Terminal.colour(label, .grey, enabled: useColour)
        case .unavailable: return Terminal.colour(label, .brightYellow, enabled: useColour)
        default: return Terminal.colour(label, .cyan, enabled: useColour)
        }
    }

    private func stateText(_ state: NodeStatus.State) -> String {
        // 10, to match the node table's header and the `used` estimate in `nodeSection`: at 8 the
        // header's latency/results/ok columns started two characters right of the data's, on every
        // frame (ledger B67).
        let label = Terminal.pad(state.label, to: 10)
        switch state {
        case .up: return Terminal.colour(label, .brightGreen, enabled: useColour)
        case .degraded: return Terminal.colour(label, .brightYellow, enabled: useColour)
        case .down: return Terminal.colour(label, .brightRed, enabled: useColour)
        case .checking: return Terminal.colour(label, .grey, enabled: useColour)
        }
    }

    // MARK: - Layout

    /// Pad a leading column and keep exactly one separating space.
    ///
    /// Padding alone does not separate columns: a value that fills its width — which is
    /// precisely what truncation produces — runs into the next column, so a long provider or
    /// node name collided with `kind` or `state`. The total width is unchanged.
    static func leadingColumn(_ text: String, width: Int) -> String {
        Terminal.pad(text, to: max(0, width - 1)) + " "
    }

    /// Render the dashboard.
    ///
    /// - Parameter fillHeight: When true the frame is sized for a screen: the sections are
    ///   capped to the available rows and blank lines push the footer to the bottom. A frame
    ///   that is not drawn to a terminal is not filling anything, so callers that redirect or
    ///   pipe the output pass false: the content is emitted in full, never padded, and no
    ///   provider is dropped to fit a screen that does not exist.
    public func render(
        _ model: MonitorModel,
        columns: Int,
        rows: Int,
        fillHeight: Bool = true
    ) -> [String] {
        let lines = compose(model, columns: columns, rows: rows, fillHeight: fillHeight)
        // Clamp width last, so no individual section has to know the limit. A wrapped line is
        // far worse than a truncated one: it shifts every subsequent row and the dashboard
        // stops being readable. Height is clamped only when a screen is being filled.
        let width = max(1, columns)
        let height = fillHeight ? max(1, rows) : lines.count
        return lines.prefix(height).map { Terminal.truncate($0, to: width) }
    }

    private func compose(
        _ model: MonitorModel,
        columns: Int,
        rows: Int,
        fillHeight: Bool
    ) -> [String] {
        var lines: [String] = []

        lines.append(contentsOf: header(model, columns: columns))
        lines.append("")

        let providerBlock = providerSection(model, columns: columns)
        let nodeBlock = nodeSection(model, columns: columns)
        let footerBlock = footer(model, columns: columns, rows: rows)

        if fillHeight {
            // Reserve space for the footer, then give the remainder to providers and nodes.
            let available = max(6, rows - lines.count - footerBlock.count)
            let nodeHeight = min(nodeBlock.count, max(3, available / 3))
            let providerHeight = max(3, available - nodeHeight)

            lines.append(contentsOf: providerBlock.prefix(providerHeight))
            if providerBlock.count > providerHeight {
                lines.append(
                    Terminal.colour(
                        "   … \(providerBlock.count - providerHeight) more",
                        .grey,
                        enabled: useColour
                    )
                )
            }

            lines.append("")
            lines.append(contentsOf: nodeBlock.prefix(nodeHeight))

            // Pad so the footer sits at the bottom rather than floating mid-screen.
            while lines.count + footerBlock.count < rows {
                lines.append("")
            }
        } else {
            // Not drawing to a screen: everything, in order, with no filler.
            lines.append(contentsOf: providerBlock)
            lines.append("")
            lines.append(contentsOf: nodeBlock)
        }

        lines.append(contentsOf: footerBlock)
        return lines
    }

    // MARK: - Header

    private func header(_ model: MonitorModel, columns: Int) -> [String] {
        let title = Terminal.bold("MCPSearch Monitor", enabled: useColour)
        let subtitle = Terminal.colour(
            "providers and nodes",
            .grey,
            enabled: useColour
        )
        let left = "  \(title)  \(subtitle)"

        let uptime = Self.duration(model.uptime)
        let right =
            "\(Terminal.colour("up", .grey, enabled: useColour)) \(uptime)  "
            + "\(Terminal.colour("cycle", .grey, enabled: useColour)) \(Self.milliseconds(model.cycleDuration))  "
            + "\(Terminal.colour("refreshed", .grey, enabled: useColour)) \(Self.clock(model.refreshedAt))  "

        var line = Terminal.pad(left, to: max(0, columns - Terminal.displayWidth(right)))
        line += right

        let rule = String(repeating: "─", count: max(0, columns))
        return [line, Terminal.colour(rule, .grey, enabled: useColour)]
    }

    // MARK: - Providers

    private func providerSection(_ model: MonitorModel, columns: Int) -> [String] {
        var lines: [String] = []

        let ok = model.providers.filter { $0.state == .healthy }.count
        let bad = model.providers.filter { $0.state == .failing }.count
        let off = model.providers.filter { $0.state == .notConfigured }.count
        let disabled = model.providers.filter { $0.state == .unavailable }.count
        var summaryParts = [
            "\(ok) ok",
            bad > 0 ? Terminal.colour("\(bad) failing", .brightRed, enabled: useColour) : "0 failing",
            "\(off) without credentials",
        ]
        // Named only when there is one: a deliberately disabled provider is not a problem
        // to report on every frame, but its absence from the summary would make the
        // OFF rows look like a miscount (ledger B76).
        if disabled > 0 { summaryParts.append("\(disabled) disabled") }
        let summary = summaryParts.joined(separator: Terminal.colour(" · ", .grey, enabled: useColour))

        lines.append("  " + Terminal.bold("PROVIDERS", enabled: useColour) + "   " + summary)
        lines.append(
            Terminal.colour(
                "  "
                    + headerRow(
                        "  provider", "kind", "state", "last", "avg", "n", "ok%", "note"
                    ),
                .grey,
                enabled: useColour
            )
        )

        for status in model.providers {
            lines.append(providerRow(status, columns: columns))
        }
        return lines
    }

    private func headerRow(
        _ provider: String, _ kind: String, _ state: String, _ last: String,
        _ average: String, _ count: String, _ rate: String, _ note: String
    ) -> String {
        Self.leadingColumn(provider, width: 17) + Terminal.pad(kind, to: 12)
            + Terminal.pad(state, to: 8) + Terminal.pad(last, to: 8, alignment: .right)
            + Terminal.pad(average, to: 8, alignment: .right)
            + Terminal.pad(count, to: 4, alignment: .right)
            + Terminal.pad(rate, to: 6, alignment: .right) + "  " + note
    }

    private func providerRow(_ status: ProviderStatus, columns: Int) -> String {
        let name = Self.leadingColumn(
            "  " + glyph(status.state) + " " + status.displayName,
            width: 17
        )
        let kind = Terminal.pad(status.kind, to: 12)
        let state = stateText(status.state)
        let last = Terminal.pad(
            status.lastLatencyMilliseconds.map { "\($0)ms" } ?? "–",
            to: 8,
            alignment: .right
        )
        let average = Terminal.pad(
            status.averageLatencyMilliseconds.map { "\($0)ms" } ?? "–",
            to: 8,
            alignment: .right
        )
        let count = Terminal.pad(
            status.probes == 0 ? "–" : "\(status.lastResultCount)",
            to: 4,
            alignment: .right
        )
        let rate = Terminal.pad(
            status.probes == 0 ? "–" : String(format: "%.0f%%", status.successRate * 100),
            to: 6,
            alignment: .right
        )

        // The note column carries whatever is most useful: the error if there is one,
        // otherwise the reason a provider is inactive.
        let note: String
        if let error = status.lastError {
            note = Terminal.colour(Terminal.sanitize(error), .brightRed, enabled: useColour)
        } else if status.state == .notConfigured {
            note = Terminal.colour("set \(status.setupHint)", .grey, enabled: useColour)
        } else if status.state == .unavailable {
            // The variable is not the fix here: the operator deliberately switched the
            // provider off, and the dashboard must not invite a probe it will refuse
            // (ledger B76).
            note = Terminal.colour(
                "disabled via SEARCH_DISABLED_PROVIDERS",
                .grey,
                enabled: useColour
            )
        } else if status.state == .configuredButIdle {
            note = Terminal.colour("ready — press p to probe", .cyan, enabled: useColour)
        } else if status.state == .healthy, let at = status.lastSuccessAt {
            note = Terminal.colour("last ok \(Self.clock(at))", .grey, enabled: useColour)
        } else {
            note = ""
        }

        let used = Terminal.displayWidth("  " + String(repeating: "x", count: 17 + 12 + 7 + 8 + 8 + 4 + 6) + "  ")
        let available = max(10, columns - used - 7)
        return name + kind + state + last + average + count + rate + "  "
            + Terminal.truncate(note, to: available)
    }

    // MARK: - Nodes

    private func nodeSection(_ model: MonitorModel, columns: Int) -> [String] {
        var lines: [String] = []

        let up = model.nodes.filter { $0.state == .up }.count
        let down = model.nodes.filter { $0.state == .down || $0.state == .degraded }.count
        let summary = [
            "\(up) up",
            down > 0 ? Terminal.colour("\(down) down/degraded", .brightRed, enabled: useColour) : "0 down",
        ].joined(separator: Terminal.colour(" · ", .grey, enabled: useColour))

        lines.append("  " + Terminal.bold("SEARXNG NODES", enabled: useColour) + "   " + summary)
        lines.append(
            Terminal.colour(
                // No extra indent here: the data rows carry their two spaces inside the name
                // column, and adding them again put the whole header two columns right of the
                // values it labels (ledger B67).
                Self.leadingColumn("  node", width: 16) + Terminal.pad("state", to: 10)
                    + Terminal.pad("latency", to: 9, alignment: .right)
                    + Terminal.pad("results", to: 9, alignment: .right)
                    + Terminal.pad("ok", to: 5, alignment: .right)
                    + (showEngines ? "  engines" : ""),
                .grey,
                enabled: useColour
            )
        )

        for node in model.nodes {
            let name = Self.leadingColumn(
                "  " + glyph(node.state) + " " + Terminal.sanitize(node.name),
                width: 16
            )
            let state = stateText(node.state)
            let latency = Terminal.pad(
                node.latencyMilliseconds.map { "\($0)ms" } ?? "–",
                to: 9,
                alignment: .right
            )
            let results = Terminal.pad(
                node.checks == 0 ? "–" : "\(node.resultCount)",
                to: 9,
                alignment: .right
            )
            let ok = Terminal.pad(
                node.checks == 0 ? "–" : String(format: "%.0f%%", node.successRate * 100),
                to: 5,
                alignment: .right
            )

            var detail = ""
            if let error = node.error {
                detail = Terminal.colour(Terminal.sanitize(error), .brightRed, enabled: useColour)
            } else if showEngines {
                let healthy = Terminal.sanitize(node.engines.joined(separator: ", "))
                detail = Terminal.colour(healthy, .grey, enabled: useColour)
                if !node.unavailableEngines.isEmpty {
                    let missing = Terminal.sanitize(node.unavailableEngines.joined(separator: ", "))
                    detail += "  " + Terminal.colour("unavailable: \(missing)", .brightYellow, enabled: useColour)
                }
            }

            let used = 16 + 10 + 9 + 9 + 5 + 2
            lines.append(
                name + state + latency + results + ok + "  "
                    + Terminal.truncate(detail, to: max(10, columns - used))
            )
        }
        return lines
    }

    // MARK: - Footer

    private func footer(_ model: MonitorModel, columns: Int, rows: Int) -> [String] {
        let rule = Terminal.colour(String(repeating: "─", count: max(0, columns)), .grey, enabled: useColour)
        var lines = [rule]

        for warning in model.warnings.prefix(2) {
            lines.append(
                "  " + Terminal.colour("⚠ " + Terminal.sanitize(warning), .brightYellow, enabled: useColour)
            )
        }

        let keys = [
            ("p", "probe providers"),
            ("r", "refresh now"),
            ("e", "toggle engines"),
            ("c", "toggle colour"),
            ("q", "quit"),
        ]
        // Lay the keys out across as many lines as needed, so a narrow terminal gets
        // readable help instead of a truncated one.
        let separator = Terminal.colour("  ·  ", .grey, enabled: useColour)
        var current = "  "
        for key in keys {
            let entry = Terminal.colour(key.0, .brightCyan, enabled: useColour) + " " + key.1
            let candidate = current == "  " ? current + entry : current + separator + entry
            if Terminal.displayWidth(candidate) > columns, current != "  " {
                lines.append(current)
                current = "  " + entry
            } else {
                current = candidate
            }
        }
        if current != "  " { lines.append(current) }
        return lines
    }

    // MARK: - Formatting

    public static func milliseconds(_ duration: Duration) -> String {
        let ms = duration.milliseconds
        return ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm%02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
