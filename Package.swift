// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Cliprill",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cliprill", targets: ["CliprillApp"]),
        .executable(name: "cliprill-mcp", targets: ["CliprillMCP"]),
        .library(name: "CliprillCore", targets: ["CliprillCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(path: "Vendor/KeyboardShortcuts")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CliprillCore", dependencies: ["CSQLite"]),
        .target(name: "CliprillClipboard", dependencies: ["CliprillCore"]),
        .executableTarget(name: "CliprillApp", dependencies: ["CliprillCore", "CliprillClipboard", "KeyboardShortcuts"], resources: [.process("Resources")]),
        .executableTarget(name: "CliprillMCP", dependencies: ["CliprillCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "CliprillCoreTests", dependencies: ["CliprillCore"]),
        .testTarget(name: "CliprillClipboardTests", dependencies: ["CliprillClipboard"])
    ],
    swiftLanguageModes: [.v5]
)
