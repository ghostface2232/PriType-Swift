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
        // Verifies an install against the machine it runs on. Not part of the
        // app: it answers what the in-process suite cannot reach.
        .executable(
            name: "pritype-device-check",
            targets: ["PriTypeDeviceCheckCLI"]),
    ],
    dependencies: [
        // Tests only: the Hanja dictionary is checked against libhangul's own
        // reading of the same hanja.txt. Composition is PriType's own
        // (`DubeolsikEngine`); nothing PriType ships links this.
        .package(url: "https://github.com/Meapri/libhangul-swift", revision: "57168458d07b21cffd28afb674a7b177fc9084a5"),
    ],
    targets: [
        .target(
            name: "PriTypeCore",
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
            dependencies: ["PriTypeCore"],
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
                "PriTypeDeviceCheck",
                .product(name: "LibHangul", package: "libhangul-swift")
            ],
            // A real signed update manifest, produced by the release workflow.
            // It is the only way a test can prove the app reads what CI writes.
            resources: [
                .copy("Fixtures")
            ]
        ),
        .target(
            name: "PriTypeDeviceCheck",
            dependencies: ["PriTypeCore"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
            ]
        ),
        .executableTarget(
            name: "PriTypeDeviceCheckCLI",
            dependencies: ["PriTypeCore", "PriTypeDeviceCheck"],
            linkerSettings: [
                .unsafeFlags(["-framework", "InputMethodKit"])
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
