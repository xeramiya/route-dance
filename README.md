# route-dance

歩行者向けのiOS ARアプリ。カメラ映像から周囲の歩行者の動きを予測し、ぶつからずに歩ける経路を映像の上に表示する。処理はすべてデバイス上で完結する。

- 仕様: [docs/SPEC.md](docs/SPEC.md)
- 技術選定: [docs/TECH_SELECTION.md](docs/TECH_SELECTION.md)
- 深度モデル: [docs/DEPTH_MODEL.md](docs/DEPTH_MODEL.md)

## 構成

```
App/Shared/                    UI（映像、オーバーレイ、HUD、コンパス、ドロワー）と動画入力。iOS / macOS 共通
App/iOS/                       ライブカメラ（AVCaptureSession＋CoreMotion）、写真ライブラリからの動画選択
App/macOS/                     動画ファイルを開く・ドラッグ＆ドロップ
Packages/RouteDanceCore/
  Sources/RouteDanceCore/      純Swiftのアルゴリズム（地面推定、オドメトリ、追跡、予測、計画）
  Sources/RouteDancePerception/ Core ML（深度）、Vision（人物検出）、フレーム処理
  Sources/RouteDanceCLI/       Macで画像・動画にパイプラインをかけるツール
Tools/ModelConversion/         深度モデル（MoGe-2）のCore ML変換
Models/                        変換済みの .mlpackage（Git管理外）
```

## セットアップ

1. 深度モデルを生成する（初回のみ。手順は [Tools/ModelConversion/README.md](Tools/ModelConversion/README.md)）。`Models/MoGe2S.mlpackage` と `Models/MoGe2S_landscape.mlpackage` ができる。
2. Xcodeのプロジェクトを生成する。
   ```sh
   brew install xcodegen
   scripts/generate.sh                                     # iOS 27 / macOS 27
   DEPLOYMENT_IOS=26.0 DEPLOYMENT_MACOS=26.0 scripts/generate.sh   # 27のSDKが入るまで
   ```
3. `RouteDance.xcodeproj` を開き、スキーム `RouteDance-iOS`（実機）か `RouteDance-macOS` を実行する。

## テスト

```sh
cd Packages/RouteDanceCore
swift test                                              # アルゴリズムのユニットテスト
swift run -c release routedance-cli <画像か動画> --models ../../Models   # パイプライン全体をMacで実行
```

Macアプリの開発用起動引数（Debugビルド）:

- `-openVideo <path>`: 起動時に動画を開く
- `-snapshot <prefix>`: 2秒ごとに画面を `<prefix>-N.png` に書き出す
