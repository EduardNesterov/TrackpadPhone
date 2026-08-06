// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TrackpadProtocol", targets: ["TrackpadProtocol"]),
        .library(name: "TrackpadInput", targets: ["TrackpadInput"]),
    ],
    targets: [
        .target(name: "TrackpadProtocol"),
        .target(name: "TrackpadInput", dependencies: ["TrackpadProtocol"]),
        .testTarget(name: "TrackpadProtocolTests", dependencies: ["TrackpadProtocol"]),
        .testTarget(name: "TrackpadInputTests", dependencies: ["TrackpadInput"]),
    ]
)
