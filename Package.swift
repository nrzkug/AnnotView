// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnnotView",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AnnotView", targets: ["AnnotView"])
    ],
    targets: [
        .executableTarget(
            name: "AnnotView",
            path: "Sources/AnnotView",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AnnotViewTests",
            dependencies: ["AnnotView"],
            path: "Tests/AnnotViewTests"
        )
    ]
)
