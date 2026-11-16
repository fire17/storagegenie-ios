// swift-tools-version:5.9
// Storage Genie for iPhone — the platform-free core (pairing, frames, commands, delete gate).
// Tested on macOS with `swift test`; the iOS app (../StorageGenie) adds Photos + iroh on top.
import PackageDescription

let package = Package(
    name: "StorageGenieCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "StorageGenieCore", targets: ["StorageGenieCore"])],
    targets: [
        .target(name: "StorageGenieCore"),
        // No XCTest in CommandLineTools: the selftest is a plain executable (`swift run sgcore-selftest`, exit 0 = PASS).
        .executableTarget(name: "sgcore-selftest", dependencies: ["StorageGenieCore"]),
    ]
)
