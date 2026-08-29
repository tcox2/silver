// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Silver",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Silver", targets: ["Silver"])
    ],
    targets: [
        .executableTarget(
            name: "Silver",
            path: "Sources/JellyPlayer"
        )
    ]
)
