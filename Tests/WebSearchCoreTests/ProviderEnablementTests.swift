import Foundation
import XCTest

@testable import WebSearchCore

/// The one authority for "which variable enables me".
final class ProviderEnablementTests: XCTestCase {

    /// Every provider states at least one requirement, and every requirement is an environment
    /// variable `AppConfiguration.Key` already knows about. The `inputs(for:)` switch is
    /// exhaustive, so a new `ProviderID` cannot compile without an entry; this pins that the
    /// entry is not empty and that its name is a real key.
    func testEveryProviderNamesAtLeastOneKnownVariable() {
        let known = Set(AppConfiguration.Key.allCases.map(\.rawValue))
        for id in ProviderID.allCases {
            let inputs = ProviderEnablement.inputs(for: id)
            XCTAssertFalse(inputs.isEmpty, "\(id.rawValue) declares no enablement requirements")
            for input in inputs {
                XCTAssertTrue(
                    known.contains(input.variableName),
                    "\(id.rawValue) names \(input.variableName), which is not an AppConfiguration.Key"
                )
            }
        }
    }

    /// Parallel is the provider that needs two inputs, in the order an operator supplies them:
    /// the switch first, then the endpoint it gates.
    func testParallelRequiresTheFlagAndThenTheEndpoint() {
        XCTAssertEqual(
            ProviderEnablement.inputs(for: .parallel),
            [.parallelEnabled, .parallelEndpoint]
        )
        for id in ProviderID.allCases where id != .parallel {
            XCTAssertEqual(
                ProviderEnablement.inputs(for: id).count, 1,
                "\(id.rawValue) is expected to need exactly one input"
            )
        }
    }

    /// The startup inventory and the "no provider is configured" error read one list,
    /// deduplicated in provider order: the two scrapers share a switch, and Parallel
    /// contributes two inputs.
    func testAllInputsAreDeduplicatedInProviderOrder() {
        let names = ProviderEnablement.allInputs.map(\.variableName)
        XCTAssertEqual(Set(names).count, names.count, "a variable is named twice: \(names)")
        XCTAssertEqual(
            names,
            [
                "TAVILY_API_KEY", "BRAVE_SEARCH_API_KEY", "MOJEEK_API_KEY", "EXA_API_KEY",
                "SEARXNG_BASE_URL", "OPEN_WEB_SEARCH_URL", "SEARCH_ENABLE_SCRAPERS",
                "SEARCH_ENABLE_PARALLEL", "PARALLEL_MCP_URL",
            ]
        )
    }

    /// The drift the finding records: with the flag on and the endpoint absent, the operator
    /// must be told about `PARALLEL_MCP_URL` — advice they have not taken — rather than the
    /// flag they already set.
    func testTheParallelInstructionNamesTheEndpointWhenTheFlagIsOn() {
        var configuration = Fixtures.configuration(enableParallel: true)
        configuration.parallelMCPURL = nil

        XCTAssertEqual(
            ProviderEnablement.missingInputs(for: .parallel, in: configuration),
            [.parallelEndpoint]
        )
        let instruction = ProviderEnablement.instruction(for: .parallel, in: configuration)
        XCTAssertTrue(instruction.contains("PARALLEL_MCP_URL"), instruction)
        XCTAssertFalse(
            instruction.contains("SEARCH_ENABLE_PARALLEL"),
            "the flag is already on, so naming it is not actionable: \(instruction)"
        )
        XCTAssertEqual(instruction, "Set PARALLEL_MCP_URL to the upstream MCP endpoint.")
    }

    func testBothParallelInputsAreNamedWhenNeitherIsPresent() {
        var configuration = Fixtures.configuration(enableParallel: false)
        configuration.parallelMCPURL = nil

        XCTAssertEqual(
            ProviderEnablement.inputsToName(for: .parallel, in: configuration),
            [.parallelEnabled, .parallelEndpoint]
        )
        XCTAssertEqual(
            ProviderEnablement.assignmentList(for: .parallel, in: configuration),
            "SEARCH_ENABLE_PARALLEL=true and PARALLEL_MCP_URL"
        )
    }

    /// Satisfaction is per input, so a provider is usable only when the whole set is present.
    func testSatisfactionTracksEveryInput() {
        var configuration = Fixtures.configuration(enableScrapers: false, enableParallel: true)
        XCTAssertTrue(ProviderEnablement.isSatisfied(.tavily, in: configuration) == false)
        XCTAssertEqual(
            ProviderEnablement.missingInputs(for: .tavily, in: configuration),
            [.tavilyAPIKey]
        )

        configuration.tavilyAPIKey = "tvly-test-key-000000000000"
        XCTAssertTrue(ProviderEnablement.isSatisfied(.tavily, in: configuration))
        // An empty string is not a credential.
        configuration.tavilyAPIKey = ""
        XCTAssertFalse(ProviderEnablement.isSatisfied(.tavily, in: configuration))

        configuration.enableScrapers = true
        XCTAssertTrue(ProviderEnablement.isSatisfied(.duckDuckGo, in: configuration))
        // Parallel has the flag on and the default endpoint present.
        XCTAssertTrue(ProviderEnablement.isSatisfied(.parallel, in: configuration))
    }

    /// The SearXNG guidance survives the consolidation, because naming the variable alone is
    /// the deployment mistake that keeps biting operators.
    func testTheSearxngInstructionKeepsItsJSONGuidance() {
        let configuration = Fixtures.configuration()
        XCTAssertEqual(
            ProviderEnablement.instruction(for: .searxng, in: configuration),
            "Set SEARXNG_BASE_URL to an instance with JSON output enabled."
        )
    }

    /// The status tool, the factory's own notes and the monitor's hint are the same authority
    /// read three times, so all three give the endpoint for this configuration.
    func testTheStatusToolAndTheMonitorHintAgreeForParallel() async {
        var configuration = Fixtures.configuration(enableParallel: true)
        configuration.parallelMCPURL = nil
        let pipeline = SearchPipelineFactory.make(
            configuration: configuration,
            http: MockHTTPClient()
        )
        let expected = ProviderEnablement.instruction(for: .parallel, in: configuration)

        // `web_search_status` overlays the registry's ineligible reason onto the health note,
        // so this is the string an operator actually sees.
        let states = await pipeline.orchestrator.status()
        let parallel = states.first { $0.provider == .parallel }
        XCTAssertEqual(parallel?.note, expected, "web_search_status must give actionable advice")
        XCTAssertTrue(parallel?.note?.contains("PARALLEL_MCP_URL") ?? false, parallel?.note ?? "")

        // The factory's own note (what `ProviderHealth` stores) is derived from the same call.
        let healthNote = await pipeline.health.state(
            for: .parallel,
            configured: pipeline.registry.isConfigured(.parallel),
            enabled: pipeline.registry.isEnabled(.parallel)
        ).note
        XCTAssertEqual(healthNote, expected)

        let probe = ProviderProbe(registry: pipeline.registry, configuration: configuration)
        XCTAssertEqual(probe.setupHint(for: .parallel), "PARALLEL_MCP_URL")
    }
}
