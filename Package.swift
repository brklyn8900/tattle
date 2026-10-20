// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tattle",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CSocketTable",
            path: "Sources/CSocketTable"
        ),
        .executableTarget(
            name: "tattle",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "CSocketTable",
            ],
            path: "Sources/tattle"
        ),
        .testTarget(
            name: "tattleTests",
            dependencies: ["tattle"],
            path: "Tests/tattleTests"
        ),
    ]
)
