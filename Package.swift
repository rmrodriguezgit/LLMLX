// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalLLM",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LocalLLM", targets: ["LocalLLM"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalLLM",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            path: "Sources/LocalLLM",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal")
            ]
        )
    ]
)
