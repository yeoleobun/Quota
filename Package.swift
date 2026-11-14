// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    targets: [
        .target(
            name: "QuotaBarCore",
            path: "Sources/QuotaBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarCore"],
            path: "Sources/QuotaBarApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBarCore"],
            path: "Tests/QuotaBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
