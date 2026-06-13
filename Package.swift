// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "avcam-cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "avcam-cli", targets: ["AvcamCLI"])
    ],
    targets: [
        .executableTarget(
            name: "AvcamCLI",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AvcamCLI/Info.plist"
                ], .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS]))
            ]
        )
    ]
)
