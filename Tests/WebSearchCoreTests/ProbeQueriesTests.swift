import Foundation
import XCTest

@testable import WebSearchCore

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
