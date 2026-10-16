// swift-tools-version: 5.9

import Foundation
import PackageDescription

// BareKit and the worker's native addons, put here by tool/worker (npm run build).
// The worker loads each addon by framework name, so all of them get embedded.
let frameworksDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Frameworks")
let frameworks = ((try? FileManager.default.contentsOfDirectory(atPath: frameworksDir.path)) ?? [])
    .filter { $0.hasSuffix(".xcframework") }
    .sorted()
let binaries: [Target] = frameworks.map { file in
    let name = String(file.dropLast(".xcframework".count))
        .map { $0.isLetter || $0.isNumber ? $0 : "_" }
    return .binaryTarget(name: String(name), path: "Frameworks/\(file)")
}

let package = Package(
    name: "qvac_flutter",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "qvac-flutter", targets: ["qvac_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "qvac_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ] + binaries.map { .target(name: $0.name) },
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                .copy("Resources/worker.bundle"),
            ]
        )
    ] + binaries
)
