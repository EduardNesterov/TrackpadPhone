// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TrackpadProtocol", targets: ["TrackpadProtocol"]),
    ],
    targets: [
        .target(name: "TrackpadProtocol"),
        .testTarget(name: "TrackpadProtocolTests", dependencies: ["TrackpadProtocol"]),
    ]
)
