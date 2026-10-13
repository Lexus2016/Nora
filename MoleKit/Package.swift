// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoleKit", targets: ["MoleKit"]),
    ],
    targets: [
        // fork/exec must not run Swift code in the child, so the PTY spawn lives in C.
        .target(name: "CPTYShim"),
        .target(name: "MoleKit", dependencies: ["CPTYShim"]),
        // Helper used by the crash-recovery test: applies an overlay, then waits for SIGKILL.
        .executableTarget(name: "molekit-spike", dependencies: ["MoleKit"]),
        .testTarget(name: "MoleKitTests", dependencies: ["MoleKit"], exclude: ["Fixtures"]),
    ]
)
