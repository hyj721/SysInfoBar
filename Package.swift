// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SysInfoBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SysInfoBar",
            path: "Sources/SysInfoBar",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
