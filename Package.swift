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
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "WebSearchCoreTests",
            dependencies: ["WebSearchCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
