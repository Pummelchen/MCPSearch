import Foundation
import XCTest

@testable import WebSearchCore

/// The `Origin` check the HTTP transport applies before any MCP handling.
///
/// The server has no authentication, so this check is what stops a browser page on another site
/// from driving it. It used to accept any host starting with `127.`, which is a *name* anybody can
/// register.
final class LoopbackOriginTests: XCTestCase {

    func testLoopbackLiteralsAndLocalhostAreAccepted() {
        for origin in [
            "http://127.0.0.1:8080",
            "https://127.0.0.1",
            "http://127.255.255.254:1",
            "http://localhost:8080",
            "http://LOCALHOST",
            "http://[::1]:8080",
        ] {
            XCTAssertTrue(LoopbackOrigin.isLoopback(origin), "\(origin) names this machine")
        }
    }

    /// A name that merely starts with `127.` is not an address — and the old prefix check accepted
    /// it.
    func testNamesThatStartWithOneTwoSevenAreNotLoopback() {
        for origin in [
            "http://127.attacker.example",
            "http://127.0.0.1.attacker.example",
            "http://127.example.com:8080",
        ] {
            XCTAssertFalse(LoopbackOrigin.isLoopback(origin), "\(origin) must be refused")
        }
    }

    /// Alternate spellings of loopback are refused: the SDK compares hosts as strings, and
    /// widening this check to resolve them would widen the surface for no benefit.
    func testAlternateSpellingsOfLoopbackAreNotAccepted() {
        for origin in [
            "http://2130706433",
            "http://0x7f.0.0.1",
            "http://127.1",
            "http://0177.0.0.1",
        ] {
            XCTAssertFalse(LoopbackOrigin.isLoopback(origin), "\(origin) must be refused")
        }
    }

    func testOtherHostsAndUnusableOriginsAreRefused() {
        for origin in [
            "http://evil.example",
            "http://128.0.0.1",
            "http://10.0.0.1",
            "https://searx.example.com",
            "not a url",
            "",
            "null",
        ] {
            XCTAssertFalse(LoopbackOrigin.isLoopback(origin), "\(origin) must be refused")
        }
    }
}
