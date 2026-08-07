// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadPhoneMac",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(path: "../../TrackpadKit"),
    ],
    targets: [
        .executableTarget(
            name: "TrackpadPhoneMac",
            dependencies: [
                .product(name: "TrackpadInput", package: "TrackpadKit"),
                .product(name: "TrackpadMac", package: "TrackpadKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
