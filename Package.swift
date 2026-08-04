// swift-tools-version: 6.2

import PackageDescription
import Foundation

var targets: [Target] = [
    .executableTarget(
        name: "AnnotView",
        path: "Sources/AnnotView",
        resources: [.process("Resources")]
    )
]

if FileManager.default.fileExists(atPath: "Tests/AnnotViewTests") {
    targets.append(
        .testTarget(
            name: "AnnotViewTests",
            dependencies: ["AnnotView"],
            path: "Tests/AnnotViewTests"
        )
    )
}

let package = Package(
    name: "AnnotView",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AnnotView", targets: ["AnnotView"])
    ],
    targets: targets
)
