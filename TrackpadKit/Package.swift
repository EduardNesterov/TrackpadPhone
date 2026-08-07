// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadKit",
    platforms: [.macOS("14.2"), .iOS(.v17)],
    products: [
        .library(name: "TrackpadProtocol", targets: ["TrackpadProtocol"]),
        .library(name: "TrackpadInput", targets: ["TrackpadInput"]),
        .library(name: "TrackpadMac", targets: ["TrackpadMac"]),
    ],
    targets: [
        .target(name: "TrackpadProtocol"),
        .target(name: "TrackpadInput", dependencies: ["TrackpadProtocol"]),
        // macOS only: this is the layer that talks to CoreGraphics. The iOS app
        // depends on TrackpadProtocol alone and never pulls it in.
        .target(name: "TrackpadMac", dependencies: ["TrackpadProtocol", "TrackpadInput"]),
        .testTarget(name: "TrackpadProtocolTests", dependencies: ["TrackpadProtocol"]),
        .testTarget(name: "TrackpadInputTests", dependencies: ["TrackpadInput"]),
    ]
)
