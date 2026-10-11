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
                .headerSearchPath("include")
            ],
            linkerSettings: [
                // Link the minimal source-built MuPDF dylib (Scripts/build-mupdf.sh).
                // Absolute path derived from #filePath: relative -L paths break
                // under SwiftPM's xcodebuild backend, which runs from a parent dir.
                .unsafeFlags([
                    "-L\(#filePath.dropLast("/Package.swift".count))/.build/mupdf-dist/lib",
                    "-lmupdf"
                ])
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
