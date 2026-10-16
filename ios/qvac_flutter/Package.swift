// swift-tools-version: 5.9

import Foundation
import PackageDescription

// BareKit and the worker's native addons. The worker loads each addon by framework
// name, so all of them get embedded. Local builds from tool/worker win over the release.
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localDir = here.appendingPathComponent("Frameworks")

struct Release: Decodable {
    let file: String
    let url: String
    let checksum: String
}

func targetName(_ file: String) -> String {
    String(String(file.dropLast(".xcframework".count)).map { $0.isLetter || $0.isNumber ? $0 : "_" })
}

let local = ((try? FileManager.default.contentsOfDirectory(atPath: localDir.path)) ?? [])
    .filter { $0.hasSuffix(".xcframework") }
    .sorted()
let binaries: [Target]
if !local.isEmpty {
    binaries = local.map { .binaryTarget(name: targetName($0), path: "Frameworks/\($0)") }
} else {
    let data = (try? Data(contentsOf: here.appendingPathComponent("release.json"))) ?? Data("[]".utf8)
    let release = (try? JSONDecoder().decode([Release].self, from: data)) ?? []
    binaries = release.map { .binaryTarget(name: targetName($0.file), url: $0.url, checksum: $0.checksum) }
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
