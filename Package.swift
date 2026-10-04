// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ObsidianJuju",
    platforms: [.macOS(.v15)],
    dependencies: [
        // JujuPix's shared core (../JujuPixCore), for viewing `.jjpx` encrypted photos. Build it first with
        // ../JujuPixCore/scripts/build-apple.sh (build_app.sh does).
        .package(path: "../JujuPixCore/bindings/swift"),
    ],
    targets: [
        // Vault scanning, Markdown metadata parsing, link resolution and the search index. No UI.
        .target(name: "ObsidianJujuCore", dependencies: [.product(name: "JujuPixCore", package: "swift")]),
        .executableTarget(name: "ObsidianJuju", dependencies: ["ObsidianJujuCore", .product(name: "JujuPixCore", package: "swift")]),
        // Run with `swift run CoreChecks` (XCTest/Testing need full Xcode).
        .executableTarget(name: "CoreChecks", dependencies: ["ObsidianJujuCore"]),
    ],
    swiftLanguageModes: [.v5]
)
