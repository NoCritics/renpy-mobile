// swift-tools-version:5.9
//
// VNPlayerCore exists so the logic that can be tested WITHOUT a device or a simulator
// actually is. Everything here is Foundation-only -- no UIKit, no SwiftUI -- so
// `swift test` runs it headlessly on the CI macOS runner in seconds, with no simulator
// boot and no code signing.
//
// The iOS app does not consume this as a package. `spike/project.yml` adds
// Sources/VNPlayerCore and Sources/ZIPFoundation to the app target directly, so the same
// files compile into the app. That keeps one copy of the source without making the
// Xcode project depend on SwiftPM resolution, which would need network at build time and
// would undermine "builds identically on any fork".
//
// ZIPFoundation is vendored source, not a dependency. See third_party/PROVENANCE.md.

import PackageDescription

let package = Package(
    name: "VNPlayerCore",
    platforms: [
        // Matches the app's floor, which is inherited from renios' own prototype.
        .macOS(.v11), .iOS(.v13),
    ],
    products: [
        .library(name: "VNPlayerCore", targets: ["VNPlayerCore"]),
    ],
    targets: [
        .target(name: "ZIPFoundation"),
        .target(name: "VNPlayerCore", dependencies: ["ZIPFoundation"]),
        .testTarget(
            name: "VNPlayerCoreTests",
            dependencies: ["VNPlayerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
