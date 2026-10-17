// swift-tools-version: 6.2
import PackageDescription

// コアは現行のmacOS 26ホストでテストを回せるよう26を下限にする（アプリ本体は27）。
let package = Package(
    name: "RouteDanceCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "RouteDanceCore", targets: ["RouteDanceCore"]),
        .library(name: "RouteDancePerception", targets: ["RouteDancePerception"]),
    ],
    targets: [
        .target(name: "RouteDanceCore"),
        .target(name: "RouteDancePerception", dependencies: ["RouteDanceCore"]),
        .testTarget(
            name: "RouteDanceCoreTests",
            dependencies: ["RouteDanceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
