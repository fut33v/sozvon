// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallListener",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CallListenerApp", targets: ["CallListenerApp"])
    ],
    targets: [
        .executableTarget(
            name: "CallListenerApp",
            path: "Sources/CallListenerApp"
        )
    ]
)
