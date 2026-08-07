// swift-tools-version: 6.0
import PackageDescription

// M0 spike. Throwaway shell around a real codec: this executable gets deleted once the
// menubar app exists, but TrackpadProtocol is keeping.
let package = Package(
    name: "mac-receiver",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../TrackpadKit"),
    ],
    targets: [
        .executableTarget(
            name: "mac-receiver",
            dependencies: [
                .product(name: "TrackpadProtocol", package: "TrackpadKit"),
                .product(name: "TrackpadInput", package: "TrackpadKit"),
                .product(name: "TrackpadMac", package: "TrackpadKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
