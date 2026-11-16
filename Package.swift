// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SenseNovaServer", platforms: [.macOS(.v26)],
    products: [.executable(name: "sensenova-server", targets: ["sensenova-server"])],
    dependencies: [
        .package(url: "https://github.com/xocialize/sensenova-u1-swift.git", revision: "0efc029d53380379d5e014eba717ae13b7ce1bcd"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3")
    ],
    targets: [
        .target(name: "ServerCore", dependencies: [.product(name: "SenseNovaU1", package: "sensenova-u1-swift"), .product(name: "MLX", package: "mlx-swift")]),
        .executableTarget(name: "sensenova-server", dependencies: ["ServerCore"]),
        .testTarget(name: "ServerCoreTests", dependencies: ["ServerCore"])
    ], swiftLanguageModes: [.v5])
