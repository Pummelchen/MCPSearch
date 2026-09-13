import Foundation
import XCTest

@testable import WebSearchCore

/// Layout and formatting primitives.
///
/// Column alignment is the whole point of a dashboard, so these are worth testing: a
/// width calculation that ignores ANSI escapes silently breaks every padded column.
final class TerminalLayoutTests: XCTestCase {

    func testDisplayWidthIgnoresEscapeSequences() {
        let styled = "\u{1B}[32mUP\u{1B}[0m"
        XCTAssertEqual(Terminal.displayWidth(styled), 2, "escapes must not count as width")
        XCTAssertEqual(Terminal.displayWidth("UP"), 2)
    }

    func testDisplayWidthCountsWideCharactersAsTwo() {
        // CJK and emoji occupy two terminal columns.
        XCTAssertEqual(Terminal.displayWidth("日本"), 4)
        XCTAssertEqual(Terminal.displayWidth("ab"), 2)
        XCTAssertEqual(Terminal.displayWidth("✓"), 1)
    }

    func testPadAlignsStyledTextCorrectly() {
        let styled = "\u{1B}[32mOK\u{1B}[0m"
        let padded = Terminal.pad(styled, to: 6)
        // Two visible characters plus four spaces, regardless of the escape bytes.
        XCTAssertEqual(Terminal.displayWidth(padded), 6)
    }

    func testPadRightAligns() {
        let padded = Terminal.pad("42", to: 6, alignment: .right)
        XCTAssertEqual(padded, "    42")
        XCTAssertEqual(Terminal.displayWidth(padded), 6)
    }

    func testTruncateAddsEllipsisAndRespectsWidth() {
        let truncated = Terminal.truncate("abcdefghij", to: 5)
        XCTAssertEqual(Terminal.displayWidth(truncated), 5)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertTrue(truncated.hasPrefix("abcd"))
    }

    func testTruncateLeavesShortTextAlone() {
        XCTAssertEqual(Terminal.truncate("abc", to: 10), "abc")
    }

    func testTruncateHandlesDegenerateWidths() {
        XCTAssertEqual(Terminal.truncate("abc", to: 0), "")
        XCTAssertEqual(Terminal.truncate("abc", to: 1), "a")
    }

    func testColourCanBeDisabled() {
        XCTAssertEqual(Terminal.colour("x", .green, enabled: false), "x")
        XCTAssertTrue(Terminal.colour("x", .green, enabled: true).contains("\u{1B}[32m"))
    }

    /// Truncating styled text counts only visible characters and never slices an escape.
    ///
    /// The per-character walk treated the escape bytes as width-1 text, so styled lines were cut
    /// short and could end in a bare `ESC` — the start of a sequence the terminal never receives
    /// the end of (ledger B53).
    func testTruncateKeepsEscapeSequencesWhole() {
        let styled = "\u{1B}[31mabcdef\u{1B}[0m"
        let truncated = Terminal.truncate(styled, to: 5)
        XCTAssertEqual(truncated, "\u{1B}[31mabcd…")
        XCTAssertEqual(Terminal.displayWidth(truncated), 5)

        // The reset must survive: a coloured line truncated without it would bleed into the next.
        let mixed = "\u{1B}[31mred\u{1B}[0m and more"
        let truncatedMixed = Terminal.truncate(mixed, to: 7)
        XCTAssertEqual(truncatedMixed, "\u{1B}[31mred\u{1B}[0m an…")
        XCTAssertEqual(Terminal.displayWidth(truncatedMixed), 7)
    }

    /// A one-column budget cannot hold a character *and* an ellipsis, and must still not emit half
    /// an escape sequence.
    func testTruncateToOneColumnDropsLeadingEscapesRatherThanSlicingThem() {
        XCTAssertEqual(Terminal.truncate("\u{1B}[31mabc", to: 1), "a")
    }

    /// Control characters are replaced, never passed to the terminal.
    ///
    /// A terminal executes these bytes: `ESC[2J` clears the screen, `ESC]52;c;…` writes the
    /// clipboard on terminals that allow it. The probe data that reaches the renderer comes
    /// from a SearXNG instance, so it is not text this program authored (ledger B25).
    func testSanitizeReplacesControlCharactersWithAVisiblePlaceholder() {
        let hostile = "brave\u{1B}]52;c;cGF3bmVk\u{07}google\u{9B}31m\n"
        let safe = Terminal.sanitize(hostile)
        XCTAssertFalse(safe.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        XCTAssertFalse(safe.unicodeScalars.contains { (0x80...0x9F).contains($0.value) })
        XCTAssertEqual(safe, "brave\u{FFFD}]52;c;cGF3bmVk\u{FFFD}google\u{FFFD}31m\u{FFFD}")
    }

    /// Format characters are replaced too: they reorder or hide text without taking a column.
    func testSanitizeStripsFormatCharactersAndLeavesOrdinaryTextAlone() {
        XCTAssertEqual(Terminal.sanitize("google cse"), "google cse")
        XCTAssertEqual(Terminal.sanitize("日本語 ✓ — dash"), "日本語 ✓ — dash")
        XCTAssertEqual(
            Terminal.sanitize("a\u{200B}b\u{202E}c\u{FEFF}d"),
            "a\u{FFFD}b\u{FFFD}c\u{FFFD}d"
        )
    }
}

/// Dashboard rendering.
final class RendererTests: XCTestCase {

    private func model(
        nodes: [NodeStatus] = [],
        providers: [ProviderStatus] = []
    ) -> MonitorModel {
        MonitorModel(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_100),
            cycleDuration: .milliseconds(1200),
            nodes: nodes,
            providers: providers,
            warnings: []
        )
    }

    private func node(_ name: String, state: NodeStatus.State) -> NodeStatus {
        NodeStatus(
            name: name,
            endpoint: "http://\(name):8888",
            state: state,
            latencyMilliseconds: 900,
            resultCount: 25,
            engines: ["brave", "google cse"],
            unavailableEngines: ["duckduckgo: CAPTCHA"],
            error: nil,
            checks: 4,
            failures: state == .up ? 0 : 1,
            lastSuccessAt: Date()
        )
    }

    private func provider(
        _ id: ProviderID,
        state: ProviderStatus.State,
        probes: Int = 3,
        successes: Int = 3,
        failures: Int = 0,
        error: String? = nil
    ) -> ProviderStatus {
        var status = ProviderStatus.pending(provider: id, configured: state != .notConfigured, hint: "TAVILY_API_KEY")
        status.state = state
        status.probes = probes
        status.successes = successes
        status.failures = failures
        status.lastLatencyMilliseconds = 1500
        status.latencyTotal = 1500 * successes
        status.lastResultCount = 5
        status.lastError = error
        status.lastSuccessAt = Date()
        return status
    }

    /// Every rendered line must fit the terminal, or the display wraps and the layout
    /// collapses into garbage.
    func testNoLineExceedsTerminalWidth() {
        for width in [60, 80, 100, 120, 200] {
            let lines = Renderer(useColour: true).render(
                model(
                    nodes: [node("this-mac", state: .up), node("node1", state: .down)],
                    providers: [
                        provider(.tavily, state: .healthy),
                        provider(.brave, state: .notConfigured, probes: 0, successes: 0),
                        provider(
                            .startpage, state: .failing, probes: 3, successes: 0, failures: 3,
                            error: "Startpage is temporarily unavailable."),
                    ]
                ),
                columns: width,
                rows: 40
            )
            for line in lines {
                XCTAssertLessThanOrEqual(
                    Terminal.displayWidth(line),
                    width,
                    "line exceeds \(width) columns: \(line)"
                )
            }
        }
    }

    /// Colour must not change the visible layout.
    func testColourDoesNotChangeVisibleWidth() {
        let withColour = Renderer(useColour: true).render(
            model(providers: [provider(.tavily, state: .healthy)]),
            columns: 100,
            rows: 30
        )
        let without = Renderer(useColour: false).render(
            model(providers: [provider(.tavily, state: .healthy)]),
            columns: 100,
            rows: 30
        )
        XCTAssertEqual(withColour.count, without.count)
        for (a, b) in zip(withColour, without) {
            XCTAssertEqual(Terminal.displayWidth(a), Terminal.displayWidth(b))
        }
    }

    /// A tiny terminal must not crash or produce thousands of lines.
    func testDegenerateTerminalSizeStillRenders() {
        for (columns, rows) in [(20, 5), (40, 8), (1, 1)] {
            let lines = Renderer(useColour: false).render(
                model(
                    nodes: [node("node1", state: .up)],
                    providers: [provider(.tavily, state: .healthy)]
                ),
                columns: columns,
                rows: rows
            )
            XCTAssertFalse(lines.isEmpty, "\(columns)x\(rows) produced nothing")
            XCTAssertLessThanOrEqual(
                lines.count,
                max(rows, 1) + 2,
                "\(columns)x\(rows) produced more lines than the terminal has rows"
            )
        }
    }

    /// The frame must never exceed the terminal height, whatever the sections produce.
    /// Overlong output scrolls, which turns a live display into an unreadable log.
    func testNeverExceedsTerminalHeight() {
        let full = model(
            nodes: (1...5).map { node("node\($0)", state: $0 == 2 ? .down : .up) },
            providers: ProviderID.allCases.map {
                provider($0, state: .healthy)
            }
        )
        for rows in [5, 10, 24, 30, 50] {
            for columns in [40, 80, 120] {
                let lines = Renderer(useColour: true).render(full, columns: columns, rows: rows)
                XCTAssertLessThanOrEqual(
                    lines.count,
                    rows,
                    "\(columns)x\(rows) produced \(lines.count) lines"
                )
            }
        }
    }

    /// Warnings are shown, because they are the most actionable thing on screen.
    func testWarningsAreRendered() {
        var m = model(providers: [provider(.tavily, state: .healthy)])
        m.warnings = ["engine 'duckduckgo' unavailable on 4 node(s)"]
        let lines = Renderer(useColour: false).render(m, columns: 140, rows: 40)
            .joined(separator: "\n")
        XCTAssertTrue(lines.contains("duckduckgo"), lines)
    }

    func testRendersNodeAndProviderNames() {
        let lines = Renderer(useColour: false).render(
            model(
                nodes: [node("node3", state: .up)],
                providers: [provider(.tavily, state: .healthy)]
            ),
            columns: 120,
            rows: 40
        ).joined(separator: "\n")

        XCTAssertTrue(lines.contains("PROVIDERS"))
        XCTAssertTrue(lines.contains("SEARXNG NODES"))
        XCTAssertTrue(lines.contains("node3"))
        XCTAssertTrue(lines.contains("Tavily"))
    }

    /// A redirected frame must not be padded to a screen it is not filling.
    ///
    /// The dashboard pads so the footer sits at the bottom of the display, which appears as a
    /// stray block of blank lines when the output is piped to a file or another program.
    func testRedirectedFrameIsNotPaddedToTheTerminalHeight() {
        let renderer = Renderer(useColour: false)
        let dashboard = model(
            nodes: [node("node1", state: .up)],
            providers: [provider(.tavily, state: .healthy)]
        )

        let piped = renderer.render(dashboard, columns: 100, rows: 40, fillHeight: false)
        XCTAssertLessThan(piped.count, 40, "a redirected frame keeps only its content")
        XCTAssertTrue(piped.last?.contains("quit") ?? false, piped.last ?? "")
        XCTAssertFalse(
            piped.suffix(2).contains(""),
            "no blank filler before the footer: \(piped.suffix(4))"
        )

        // The interactive frame still fills the screen so the footer stays at the bottom.
        let interactive = renderer.render(dashboard, columns: 100, rows: 40, fillHeight: true)
        XCTAssertEqual(interactive.count, 40)
        XCTAssertTrue(interactive.last?.contains("quit") ?? false)
    }

    /// Nothing may be dropped to fit a screen that is not being filled.
    func testRedirectedFrameKeepsEveryProvider() {
        let ids: [ProviderID] = [
            .tavily, .brave, .mojeek, .exa, .searxng, .openWebSearch, .duckDuckGo, .startpage,
            .parallel,
        ]
        // Deliberately shorter than the content: the interactive path would cap the section.
        let piped = Renderer(useColour: false).render(
            model(providers: ids.map { provider($0, state: .healthy) }),
            columns: 120,
            rows: 12,
            fillHeight: false
        )

        XCTAssertGreaterThan(piped.count, 12)
        XCTAssertFalse(
            piped.contains { $0.contains("more") },
            "no provider may be hidden in a redirected frame"
        )
        // The name column is narrower than the longest names, so match on a prefix: a
        // truncated name is still that provider's row.
        for id in ids {
            let prefix = String(id.displayName.prefix(8))
            XCTAssertTrue(
                piped.contains { $0.contains(prefix) },
                "\(id.displayName) is missing from the redirected frame"
            )
        }
    }

    /// A value that fills its column must still be separated from the next one.
    ///
    /// Padding alone does not separate columns: truncation returns a string of exactly the
    /// column width, so the longest provider name ran into `kind` and the longest node name
    /// into `state`. Seen on a live dashboard, which rendered "Open Web Se…aggregator".
    func testTruncatedNamesKeepTheirColumnSeparator() {
        let rendered = Renderer(useColour: false).render(
            model(
                nodes: [node("a-very-long-node-name", state: .up)],
                providers: [provider(.openWebSearch, state: .notConfigured)]
            ),
            columns: 140,
            rows: 40
        )

        let providerLine = rendered.first { $0.contains("Open Web") }
        XCTAssertNotNil(providerLine)
        XCTAssertFalse(
            providerLine?.contains("…aggregator") ?? false,
            "the truncated provider name runs into the kind column: \(providerLine ?? "")"
        )
        XCTAssertTrue(providerLine?.contains("… aggregator") ?? false, providerLine ?? "")

        // The node name column is narrower, so the name truncates earlier.
        let nodeLine = rendered.first { $0.contains("a-very-lon") }
        XCTAssertNotNil(nodeLine)
        XCTAssertFalse(
            nodeLine?.contains("…UP") ?? false,
            "the truncated node name runs into the state column: \(nodeLine ?? "")"
        )
    }

    func testFailureMessageIsShown() {
        let lines = Renderer(useColour: false).render(
            model(providers: [
                provider(
                    .startpage, state: .failing, probes: 2, successes: 0, failures: 2,
                    error: "Startpage is temporarily unavailable.")
            ]),
            columns: 140,
            rows: 40
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("temporarily unavailable"), lines)
    }

    func testUnconfiguredProviderShowsItsSetupHint() {
        let lines = Renderer(useColour: false).render(
            model(providers: [
                provider(.brave, state: .notConfigured, probes: 0, successes: 0)
            ]),
            columns: 140,
            rows: 40
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("TAVILY_API_KEY"), "the hint should name the variable")
    }

    func testDegradedNodeShowsUnavailableEngines() {
        let lines = Renderer(useColour: false, showEngines: true).render(
            model(nodes: [node("node1", state: .up)]),
            columns: 200,
            rows: 40
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("unavailable"))
        XCTAssertTrue(lines.contains("duckduckgo"))
    }

    func testEngineColumnCanBeHidden() {
        let lines = Renderer(useColour: false, showEngines: false).render(
            model(nodes: [node("node1", state: .up)]),
            columns: 200,
            rows: 40
        ).joined(separator: "\n")
        XCTAssertFalse(lines.contains("unavailable"))
        // The column header must go with the data: leaving it says the table shows engines
        // when it does not.
        XCTAssertFalse(
            lines.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("node")
                    && $0.trimmingCharacters(in: .whitespaces).hasSuffix("engines")
            },
            lines
        )
    }

    func testDurationFormatting() {
        XCTAssertEqual(Renderer.duration(5), "5s")
        XCTAssertEqual(Renderer.duration(65), "1m05s")
        XCTAssertEqual(Renderer.duration(3725), "1h02m")
    }

    /// The node table's header and data columns line up.
    ///
    /// The header padded the state column to 10 while every data row padded it to 8, so the
    /// header's latency/results/ok labels sat two characters right of the values they described on
    /// every frame (ledger B67).
    func testNodeTableHeaderAlignsWithItsData() {
        let lines = Renderer(useColour: false).render(
            model(
                nodes: [node("node1", state: .up)],
                providers: [provider(.tavily, state: .healthy)]
            ),
            columns: 140,
            rows: 40
        )

        let header = lines.first { $0.contains("latency") } ?? ""
        let row = lines.first { $0.contains("900ms") } ?? ""
        let headerEnd = header.range(of: "latency").map {
            Terminal.displayWidth(String(header[header.startIndex..<$0.upperBound]))
        }
        let rowEnd = row.range(of: "900ms").map {
            Terminal.displayWidth(String(row[row.startIndex..<$0.upperBound]))
        }

        XCTAssertNotNil(headerEnd, "the node table must have a header")
        XCTAssertNotNil(rowEnd, "the node table must show the stub latency")
        XCTAssertEqual(headerEnd, rowEnd, "the latency column ends at the same column in both rows")
    }

    func testMillisecondFormatting() {
        XCTAssertEqual(Renderer.milliseconds(.milliseconds(750)), "750ms")
        XCTAssertEqual(Renderer.milliseconds(.milliseconds(1500)), "1.5s")
    }

    /// Text a probed instance controls must not be able to drive the operator's terminal.
    ///
    /// Engine names, `unresponsive_engines` reasons and error bodies arrive from SearXNG and are
    /// rendered straight into the frame. A terminal executes what it is handed, so an instance
    /// could clear the screen, move the cursor, or write the clipboard through OSC 52 using
    /// nothing but an engine name. The frame may therefore contain no escape sequence other than
    /// the colouring the renderer itself generates (ledger B25).
    func testHostileInstanceTextCannotDriveTheTerminal() {
        var injecting = node("node1", state: .up)
        injecting.engines = ["brave\u{1B}]52;c;cGF3bmVk\u{07}", "google cse"]
        injecting.unavailableEngines = ["duckduckgo\u{1B}[2JSPOOF: CAPTCHA"]
        var failing = node("node2", state: .degraded)
        failing.error = "connection refused\u{1B}[31m\u{9B}1;2H"
        failing.name = "node2\u{1B}]0;spoofed title\u{07}"

        var model = self.model(
            nodes: [injecting, failing],
            providers: [provider(.tavily, state: .healthy, error: "boom\u{1B}[2J")]
        )
        model.warnings = ["engine 'duckduckgo\u{1B}[2J' unavailable on 4 node(s)"]

        let rendered = Renderer(useColour: true)
            .render(model, columns: 200, rows: 40)
            .joined(separator: "\n")

        for sequence in escapeSequences(in: rendered) {
            XCTAssertTrue(
                Self.isOwnColouring(sequence),
                "the dashboard may only emit its own colouring, found \(sequence.debugDescription)"
            )
        }
        XCTAssertFalse(
            rendered.unicodeScalars.contains { (0x80...0x9F).contains($0.value) },
            "a bare C1 control character reached the frame"
        )
        XCTAssertTrue(
            rendered.contains("\u{FFFD}"),
            "the payload must be replaced with a visible placeholder, not dropped silently"
        )
        XCTAssertTrue(rendered.contains("google cse"), "legitimate engine names still render")
    }

    /// The escape sequences in `text`, terminated the same way `Terminal.displayWidth` does.
    private func escapeSequences(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while let start = text[index...].firstIndex(of: "\u{1B}") {
            var cursor = text.index(after: start)
            while cursor < text.endIndex, !text[cursor].isLetter {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else {
                found.append(String(text[start...]))
                break
            }
            found.append(String(text[start...cursor]))
            index = text.index(after: cursor)
        }
        return found
    }

    /// Whether a sequence is one the renderer generates itself: `ESC [ <digits and ;> m`.
    private static func isOwnColouring(_ sequence: String) -> Bool {
        guard sequence.hasPrefix("\u{1B}["), sequence.hasSuffix("m") else { return false }
        return sequence.dropFirst(2).dropLast().allSatisfy { $0.isNumber || $0 == ";" }
    }
}

/// Metric accumulation.
final class MonitorModelTests: XCTestCase {

    func testNodeCountersAccumulateAcrossProbes() {
        var status = NodeStatus.pending(name: "node1", endpoint: "http://node1:8888")
        XCTAssertEqual(status.checks, 0)
        XCTAssertEqual(status.successRate, 0, "a node never probed has no success rate")

        // Two successes and one failure.
        status = status.applying(
            NodeProbe.Result(
                state: .up, latencyMilliseconds: 100, resultCount: 25,
                engines: ["brave"], unavailableEngines: [], error: nil)
        )
        status = status.applying(
            NodeProbe.Result(
                state: .up, latencyMilliseconds: 200, resultCount: 25,
                engines: ["brave"], unavailableEngines: [], error: nil)
        )
        status = status.applying(
            NodeProbe.Result(
                state: .down, latencyMilliseconds: nil, resultCount: 0,
                engines: [], unavailableEngines: [], error: "unreachable")
        )

        XCTAssertEqual(status.checks, 3)
        XCTAssertEqual(status.failures, 1)
        XCTAssertEqual(status.state, .down)
        XCTAssertEqual(status.successRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(status.latencyMilliseconds, nil)
        XCTAssertNotNil(status.lastSuccessAt)
    }

    func testProviderCountersAndAverageLatency() {
        var status = ProviderStatus.pending(provider: .tavily, configured: true, hint: "TAVILY_API_KEY")

        status = status.applying(.success(latencyMilliseconds: 1000, resultCount: 5))
        status = status.applying(.success(latencyMilliseconds: 3000, resultCount: 4))
        status = status.applying(.failure(error: "boom", category: .serverError, latencyMilliseconds: 500))

        XCTAssertEqual(status.probes, 3)
        XCTAssertEqual(status.successes, 2)
        XCTAssertEqual(status.failures, 1)
        XCTAssertEqual(status.state, .failing, "the most recent outcome decides the state")
        XCTAssertEqual(status.successRate, 2.0 / 3.0, accuracy: 0.0001)
        // Average is over successful probes only, so a slow failure cannot skew it.
        XCTAssertEqual(status.averageLatencyMilliseconds, 2000)
        XCTAssertEqual(status.lastError, "boom")
        XCTAssertEqual(status.lastErrorCategory, .serverError)
    }

    func testProviderRecoversAndShowsHealthyAgain() {
        var status = ProviderStatus.pending(provider: .tavily, configured: true, hint: "")
        status = status.applying(.failure(error: "down", category: .serverError))
        XCTAssertEqual(status.state, .failing)
        status = status.applying(.success(latencyMilliseconds: 800, resultCount: 5))
        XCTAssertEqual(status.state, .healthy)
        XCTAssertEqual(status.lastError, nil, "a recovery clears the stale error")
    }

    func testProviderKindClassification() {
        // The kind column explains why a provider is weighted the way it is.
        XCTAssertEqual(ProviderStatus.kind(of: .tavily), "index")
        XCTAssertEqual(ProviderStatus.kind(of: .brave), "index")
        XCTAssertEqual(ProviderStatus.kind(of: .duckDuckGo), "scraper")
        XCTAssertEqual(ProviderStatus.kind(of: .startpage), "scraper")
        XCTAssertEqual(ProviderStatus.kind(of: .searxng), "aggregator")
        XCTAssertEqual(ProviderStatus.kind(of: .parallel), "aggregator")
    }
}

/// Probe query rotation.
final class ProbeQueriesTests: XCTestCase {
    func testQueriesRotateSoRepeatedProbesDoNotAllHitTheSamePage() {
        var queries = ProbeQueries()
        let first = queries.next()
        var seen = Set([first])
        for _ in 0..<9 { seen.insert(queries.next()) }
        XCTAssertGreaterThan(seen.count, 1, "probe queries should rotate")
        // And the rotation is stable and finite.
        XCTAssertEqual(queries.next(), first)
    }

}
