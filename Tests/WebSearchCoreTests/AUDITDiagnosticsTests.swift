import Foundation
import XCTest

@testable import WebSearchCore

/// TEMPORARY audit diagnostic — not part of the product suite.
///
/// Purpose: attribute the AddressSanitizer crash seen in
/// `ProviderContractTests.testDuckDuckGoTaxonomy` (ledger item A01). It feeds the same
/// 23-byte non-HTML body at three depths: the SwiftSoup wrapper, the shared scraper
/// parser, and the DuckDuckGo provider. Deleted before the audit branch merges.
final class AUDITDiagnosticsTests: XCTestCase {

    private static let junkBody = "this is not json at all"

    /// A. The shared scraper parser, which calls SwiftSoup directly.
    func testA_scraperSupportParsesJunkAsHTML() throws {
        _ = try ScraperSupport.parse(
            html: Self.junkBody,
            containerSelectors: [".result"],
            linkSelectors: ["a"],
            snippetSelectors: [".snippet"],
            base: "https://duckduckgo.com",
            excludeHosts: ["duckduckgo.com"],
            provider: .duckDuckGo
        )
    }

    /// B. The DuckDuckGo provider with an HTTP 200 whose body is not HTML.
    func testB_duckDuckGoProviderOnAJunkBody() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(Self.junkBody.utf8),
                url: request.url
            )
        }
        let provider = DuckDuckGoProvider(
            http: http,
            configuration: Fixtures.configuration(enableScrapers: true),
            scrapersEnabled: true
        )
        do {
            _ = try await provider.search(Fixtures.request())
            XCTFail("a non-markup body must not produce results")
        } catch let error as SearchError {
            XCTAssertEqual(error.category, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// C. The same provider with a well-formed but empty HTML document.
    func testC_duckDuckGoProviderOnEmptyHTML() async {
        let http = MockHTTPClient()
        http.onAny { request in
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/html"],
                body: Data("<html><body></body></html>".utf8),
                url: request.url
            )
        }
        let provider = DuckDuckGoProvider(
            http: http,
            configuration: Fixtures.configuration(enableScrapers: true),
            scrapersEnabled: true
        )
        _ = try? await provider.search(Fixtures.request())
    }
}

// MARK: - Deep-nesting threshold probe (temporary audit tooling, A01)

extension AUDITDiagnosticsTests {

    /// D. How deep can untrusted HTML be before the parse dies *without* a sanitizer?
    ///
    /// Prints the depth to stderr and flushes before each attempt, so a crash identifies
    /// the threshold. Runs through the DuckDuckGo provider, i.e. on a cooperative task.
    func testD_deepNestingThresholdWithoutASan() async {
        for depth in [1_000, 5_000, 20_000, 100_000, 300_000] {
            FileHandle.standardError.write(Data("AUDIT depth=\(depth) start\n".utf8))
            let html = String(repeating: "<div>", count: depth) + "text"
            let http = MockHTTPClient()
            http.onAny { request in
                HTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "text/html"],
                    body: Data(html.utf8),
                    url: request.url
                )
            }
            let provider = DuckDuckGoProvider(
                http: http,
                configuration: Fixtures.configuration(enableScrapers: true),
                scrapersEnabled: true
            )
            do {
                _ = try await provider.search(Fixtures.request())
                FileHandle.standardError.write(Data("AUDIT depth=\(depth) survived (results)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("AUDIT depth=\(depth) survived (error: \(error))\n".utf8))
            }
        }
    }

    /// E. The same shape through `web_open`'s extraction path.
    func testE_deepNestingThroughHTMLExtraction() async {
        for depth in [20_000, 100_000, 300_000] {
            FileHandle.standardError.write(Data("AUDIT extract depth=\(depth) start\n".utf8))
            let html = String(repeating: "<div>", count: depth) + "text"
            do {
                _ = try HTMLExtractor.extract(html: html)
                FileHandle.standardError.write(Data("AUDIT extract depth=\(depth) survived\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("AUDIT extract depth=\(depth) survived (error: \(error))\n".utf8))
            }
        }
    }
}
