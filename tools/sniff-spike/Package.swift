// swift-tools-version: 5.10
import PackageDescription

// Standalone spike, deliberately outside the app package: it measures how many outbound
// connections a BPF sniffer can name on this machine before the Network tab depends on it.
let package = Package(
    name: "sniff-spike",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "CBPF", path: "Sources/CBPF"),
        .executableTarget(
            name: "sniff-spike",
            dependencies: ["CBPF"],
            path: "Sources/sniff-spike"
        ),
    ]
)
