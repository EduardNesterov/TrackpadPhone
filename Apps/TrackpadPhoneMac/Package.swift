// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadPhoneMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../TrackpadKit"),
    ],
    targets: [
        .executableTarget(
            name: "TrackpadPhoneMac",
            dependencies: [
                .product(name: "TrackpadInput", package: "TrackpadKit"),
                .product(name: "TrackpadProtocol", package: "TrackpadKit"),
                .product(name: "TrackpadMac", package: "TrackpadKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
