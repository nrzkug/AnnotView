// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnnotView",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AnnotView", targets: ["AnnotView"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
    ],
    targets: [
        .target(
            name: "CMuPDF",
            path: "Sources/CMuPDF",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lmupdf"])
            ]
        ),
        .executableTarget(
            name: "AnnotView",
            dependencies: [
                "CMuPDF",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AnnotView",
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "AnnotViewTests",
            dependencies: [
                "AnnotView",
                "CMuPDF",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Tests/AnnotViewTests",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)
