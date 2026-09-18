import Foundation
import XCTest

@testable import WebSearchCore

/// URL canonicalization and deduplication behaviour.
///
/// The canonical form is the deduplication key, so these tests are the contract that
/// keeps duplicate results from inflating confidence during fusion.
final class URLCanonicalizerTests: XCTestCase {

    func testLowercasesHostAndStripsFragment() {
        let canonical = URLCanonicalizer.canonicalize(
            URL(string: "https://Example.COM/Path/Page#section-3")!
        )
        XCTAssertEqual(canonical.absoluteString, "https://example.com/Path/Page")
    }

    func testRemovesTrackingParametersButKeepsIdentityParameters() {
        let url = URL(
            string: "https://example.com/a?id=42&utm_source=news&utm_campaign=x&gclid=abc&page=2&fbclid=z"
        )!
        let canonical = URLCanonicalizer.canonicalize(url)
        XCTAssertEqual(canonical.absoluteString, "https://example.com/a?id=42&page=2")
    }

    func testPreservesMeaningfulQueryParametersInOrder() {
        let url = URL(string: "https://example.com/search?q=swift&v=6.3&t=all")!
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(url).absoluteString,
            "https://example.com/search?q=swift&v=6.3&t=all"
        )
    }

    func testNormalizesDefaultPorts() {
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com:443/x")!)
                .absoluteString,
            "https://example.com/x"
        )
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "http://example.com:80/x")!)
                .absoluteString,
            "http://example.com/x"
        )
        // A non-default port must survive: it can select a different resource.
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com:8443/x")!)
                .absoluteString,
            "https://example.com:8443/x"
        )
    }

    func testNormalizesTrailingSlashAndEmptyPath() {
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com/a/b/")!)
                .absoluteString,
            "https://example.com/a/b"
        )
        // Bare host and host-with-root-slash must agree.
        XCTAssertEqual(
            URLCanonicalizer.canonicalize(URL(string: "https://example.com")!).absoluteString,
            URLCanonicalizer.canonicalize(URL(string: "https://example.com/")!).absoluteString
        )
    }

    func testNormalizesPercentEncodingCase() {
        let upper = URLCanonicalizer.canonicalize(URL(string: "https://example.com/a%7Eb")!)
        let plain = URLCanonicalizer.canonicalize(URL(string: "https://example.com/a~b")!)
        // `~` is unreserved, so both spellings must collapse to the same key.
        XCTAssertEqual(upper.absoluteString, plain.absoluteString)
    }

    func testStripsUserInfoSoCredentialsNeverReachDedupKeys() {
        let canonical = URLCanonicalizer.canonicalize(
            URL(string: "https://user:secret@example.com/page")!
        )
        XCTAssertEqual(canonical.absoluteString, "https://example.com/page")
    }

    func testLeavesNonHTTPURLsAlone() {
        let fileURL = URL(string: "file:///tmp/secret.txt")!
        XCTAssertEqual(URLCanonicalizer.canonicalize(fileURL), fileURL)
    }

    func testDeduplicatesEquivalentURLs() throws {
        let variants = [
            "https://Example.com/Article?utm_source=a#top",
            "https://example.com/Article/",
            "http://example.com:80/Article",
            "https://example.com/Article?utm_medium=b",
        ]
        let keys = Set(try variants.map { URLCanonicalizer.key(for: try XCTUnwrap(URL(string: $0))) })
        // The http/https pair legitimately differs; everything else must collapse.
        XCTAssertEqual(keys.count, 2, "expected http and https to remain distinct: \(keys)")
    }

    func testDoesNotCollapseDifferentResources() {
        let a = URLCanonicalizer.key(for: URL(string: "https://example.com/a")!)
        let b = URLCanonicalizer.key(for: URL(string: "https://example.com/b")!)
        let c = URLCanonicalizer.key(for: URL(string: "https://other.com/a")!)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: Domain matching

    func testNormalizeDomainHandlesCommonSpellings() {
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("WWW.Example.COM"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("*.example.com"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain(".example.com"), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("example.com."), "example.com")
        XCTAssertEqual(URLCanonicalizer.normalizeDomain("https://www.example.com/path"), "example.com")
    }

    func testHostMatchesDomainRespectsSubdomainBoundaries() {
        XCTAssertTrue(URLCanonicalizer.host("example.com", matchesDomain: "example.com"))
        XCTAssertTrue(URLCanonicalizer.host("docs.example.com", matchesDomain: "example.com"))
        XCTAssertTrue(URLCanonicalizer.host("docs.example.com", matchesDomain: "www.example.com"))
        // A suffix match must not treat a different registrable domain as included.
        XCTAssertFalse(URLCanonicalizer.host("notexample.com", matchesDomain: "example.com"))
        XCTAssertFalse(URLCanonicalizer.host("example.com.evil.net", matchesDomain: "example.com"))
    }
}
