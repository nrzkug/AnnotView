// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Fail manifest evaluation with an actionable message when the minimal MuPDF
// build hasn't been staged — otherwise the first sign of trouble is a cryptic
// `ld: library 'mupdf' not found` at link time.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let mupdfDylibPath = packageRoot + "/.build/mupdf-dist/lib/libmupdf.dylib"
if !FileManager.default.fileExists(atPath: mupdfDylibPath) {
    fatalError("""
    libmupdf.dylib not found at \(mupdfDylibPath).
    Run Scripts/build-mupdf.sh once before `swift build` / `swift test`
    (or just run Scripts/package.sh, which invokes it automatically).
    """)
}

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
                // Absolute path: relative -L paths break under SwiftPM's
                // xcodebuild backend, which runs from a parent dir.
                .unsafeFlags([
                    "-L\(packageRoot)/.build/mupdf-dist/lib",
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
            resources: [.process("Resources/ToolbarIcons.xcassets"), .copy("Resources/LICENSE.lucide")],
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
