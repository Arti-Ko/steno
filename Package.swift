// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Steno",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StenoTests",
            dependencies: ["Steno"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
