// swift-tools-version: 6.2
import PackageDescription

// コアは現行のmacOS 26ホストでテストを回せるよう26を下限にする（アプリ本体は27）。
let optimizeInDebug: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "RouteDanceCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "RouteDanceCore", targets: ["RouteDanceCore"]),
        .library(name: "RouteDancePerception", targets: ["RouteDancePerception"]),
        .executable(name: "routedance-cli", targets: ["RouteDanceCLI"]),
    ],
    targets: [
        // 数値計算（フロー、計画、深度の後処理）はDebugでも最適化しないと実時間で動かないので -O を付ける。
        .target(name: "RouteDanceCore", swiftSettings: optimizeInDebug),
        .target(name: "RouteDancePerception", dependencies: ["RouteDanceCore"], swiftSettings: optimizeInDebug),
        // Macで画像・動画にパイプラインをかけて結果を出すツール（ヘッドレスの動作確認と評価用）。
        .executableTarget(name: "RouteDanceCLI", dependencies: ["RouteDanceCore", "RouteDancePerception"]),
        .testTarget(
            name: "RouteDanceCoreTests",
            dependencies: ["RouteDanceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
