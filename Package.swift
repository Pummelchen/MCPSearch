// swift-tools-version: 6.3
// SwiftWebSearchMCP — a Swift-native web search MCP server.

import PackageDescription

let package = Package(
    name: "SwiftWebSearchMCP",
    platforms: [
        // The MCP Swift SDK 0.12.1 declares macOS 13 as its minimum.
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SwiftWebSearchMCP", targets: ["SwiftWebSearchMCP"]),
        // Named for the shell: the product name is what the binary is called.
        .executable(name: "mcps-mon", targets: ["MCPSMonitor"]),
        .library(name: "WebSearchCore", targets: ["WebSearchCore"]),
    ],
    dependencies: [
        // Pinned exactly for reproducible builds.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            exact: "2.13.5"
        ),
        // Used by the optional Streamable HTTP transport. The MCP SDK already depends
        // on swift-nio, so this adds no new download to the graph; it is declared
        // directly because the HTTP server that fronts the SDK's transport needs it.
        //
        // Pinned exactly, like the other two direct dependencies (ledger A05). A production
        // server must ship the dependency graph that was tested: `Package.resolved` already
        // fixes the version for a checked-out build, but a `from:` range lets a fresh resolve
        // or `swift package update` move the HTTP transport to an untested release without any
        // change to this repository. Updating is then a reviewed change to this file (a
        // Dependabot bump, or `swift package update` plus a lockfile diff), which is what the
        // other two dependencies already require.
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.102.0"
        ),
    ],
    targets: [
        // All search, fetch and reliability logic. Contains no MCP-specific code
        // so that it stays testable without a transport.
        .target(
            name: "WebSearchCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The MCP surface. Knows about MCP; knows almost nothing about vendors.
        .executableTarget(
            name: "SwiftWebSearchMCP",
            dependencies: [
                "WebSearchCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "WebSearchCoreTests",
            dependencies: ["WebSearchCore"],
            // No resource bundle: every test fixture is an inline Swift literal. A
            // `.copy("Fixtures")` declaration previously pointed at a directory that
            // was not tracked in git, which broke clean checkouts.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // A live terminal dashboard for providers and nodes. Runs on the machine the
        // operator is looking at, and depends only on the core library so it can be
        // built without the server's MCP stack.
        .executableTarget(
            name: "MCPSMonitor",
            dependencies: ["WebSearchCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Options parsing lives in the executable, so testing it needs the executable as
        // a dependency. SwiftPM supports that for executable targets.
        .testTarget(
            name: "MCPSMonitorTests",
            dependencies: ["MCPSMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
