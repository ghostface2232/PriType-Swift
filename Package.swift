// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PriType",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v14)  // Sonoma or later
    ],
    products: [
        .executable(
            name: "PriType",
            targets: ["PriType"]),
        .library(
            name: "PriTypeCore",
            targets: ["PriTypeCore"]),
    ],
    dependencies: [
        // Pinned to the revision PriType is tested against. The newest tag,
        // v3.0.3, predates 43 commits PriType builds on, and `main` has since
        // moved to data-driven keyboards that nothing here has run with. Move
        // this pin deliberately, after the tests pass.
        .package(url: "https://github.com/Meapri/libhangul-swift", revision: "57168458d07b21cffd28afb674a7b177fc9084a5"),
    ],
    targets: [
        .target(
            name: "PriTypeCore",
            dependencies: [
                .product(name: "LibHangul", package: "libhangul-swift")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .executableTarget(
            name: "PriType",
            dependencies: [
                "PriTypeCore",
                .product(name: "LibHangul", package: "libhangul-swift")
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .target(
            name: "PriTypeIMKHarness",
            dependencies: ["PriTypeCore"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .executableTarget(
            name: "PriTypeHanjaCompiler",
            dependencies: ["PriTypeCore"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .testTarget(
            name: "PriTypeCoreTests",
            dependencies: [
                "PriTypeCore",
                "PriTypeIMKHarness",
                .product(name: "LibHangul", package: "libhangul-swift")
            ]
        ),
        .executableTarget(
            name: "PriTypeBenchmark",
            dependencies: ["PriTypeCore", "PriTypeIMKHarness"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        )
    ]
)
