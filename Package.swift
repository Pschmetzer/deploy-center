// swift-tools-version:6.0
// For Xcode and SourceKit only: `open Package.swift` gives the app's sources code completion, jump to
// definition and live errors. The release build stays ./build.sh (universal binary, Sparkle framework,
// signing, widgets). Nothing here is built by CI or shipped. Pin Sparkle like scripts/sparkle.sh.
import PackageDescription

let package = Package(
    name: "DeployCenter",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "DeployCenter", targets: ["DeployCenter"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "DeployCenter",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            exclude: ["app/AppIcon.icns", "app/Assets.xcassets"],
            sources: ["app", "shared"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
