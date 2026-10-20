// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenLink",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenLink", targets: ["ScreenLink"])],
    targets: [
        .target(name: "ScreenLinkCore"),
        .executableTarget(name: "ScreenLink", dependencies: ["ScreenLinkCore"]),
        .executableTarget(name: "ScreenLinkChecks", dependencies: ["ScreenLinkCore"], path: "Tests/ScreenLinkCoreTests")
    ]
)
