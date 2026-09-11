// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcp-spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Latest tagged release checked on September 10, 2026; Version.supported
        // includes 2025-06-18. Exact pin, deliberately not SDK main.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(name: "mcp-spike", dependencies: [.product(name: "MCP", package: "swift-sdk")])
    ]
)
