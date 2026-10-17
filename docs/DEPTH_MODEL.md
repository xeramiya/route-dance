# 単眼メトリック深度モデル（MoGe-2 ViT-S）

> 調査・変換日: 2026-10-17
> 関連: [TECH_SELECTION.md](TECH_SELECTION.md)、再現手順は [Tools/ModelConversion/README.md](../Tools/ModelConversion/README.md)

## 1. 採用モデル

| 項目 | 内容 |
| --- | --- |
| モデル | **MoGe-2 ViT-S（normal版）** `Ruicheng/moge-2-vits-normal` |
| 規模 | 35.1Mパラメータ（DINOv2 ViT-S/14 エンコーダ＋畳み込みデコーダ） |
| ライセンス | **MIT**（コード、重みとも）。DINOv2部分のコードはMeta AIのApache-2.0。**非商用制限なし** |
| 出力 | アフィン不変の点群、マスク、メトリックスケール。後処理でメートル深度とカメラ内部パラメータ（画角）が得られる |
| 採用理由 | 動画で内部パラメータが不明でも、画角と地面までの距離を同時に推定できる。Macで37ms（ANE）と十分に速く、Core ML変換も成功した |

代替（今回は使わなかった。変換が成功し速度の目標も満たしたため）:

| 候補 | ライセンス | 備考 |
| --- | --- | --- |
| `apple/coreml-depth-anything-v2-small` | Apache-2.0（HFのメタデータで確認） | 相対深度のみ。M4 Proで22ms（518x392、`.all`も`.cpuAndNeuralEngine`も同じ）。メトリック化と画角推定ができないので、MoGe-2の補助・比較用 |
| `Depth-Anything-V2-Metric-Outdoor-Small-hf` | HFのメタデータにライセンス記載なし。**未確認** | DA-V2のSmallはApache-2.0だが、メトリック版は確認できていない。屋外（Virtual KITTI）専用。**採用する場合は先にライセンスを確認すること** |
| Depth Anything 3 Small | Apache-2.0 | 参考のみ。未評価 |

## 2. 成果物

`Models/`（`.gitignore` 済み。`Tools/ModelConversion/convert_moge.py` で再生成できる）

| ファイル | 入力 W×H | トークン格子 | 用途 |
| --- | --- | --- | --- |
| `MoGe2S.mlpackage` | 378×504 | 27×36（972） | **標準。縦持ち 3:4** |
| `MoGe2S_landscape.mlpackage` | 504×378 | 36×27（972） | 横持ち 4:3 |
| `MoGe2S_9x16.mlpackage` | 378×672 | 27×48（1296） | 縦持ち 9:16（iPhoneの標準動画。画像を歪ませずに入れたい場合） |
| `MoGe2S_16x9.mlpackage` | 672×378 | 48×27（1296） | 横持ち 16:9 |

サイズは62MB。形式は mlprogram、FP16、最小デプロイターゲット iOS 18 / macOS 15。バッチは1固定。
速度優先の336×448（768トークン）は `convert_moge.py` で作れる（§5）。

## 3. 入出力仕様

### 入力

| 名前 | 型 | 形状 | 値域 |
| --- | --- | --- | --- |
| `image` | `ImageType`（**RGB**、`kCVPixelFormatType_32BGRA`などのCVPixelBufferでも可） | `1×3×H×W`（上表のサイズ） | 画素値 0〜255（モデル内で `/255` とImageNet正規化 `mean=(0.485,0.456,0.406)`、`std=(0.229,0.224,0.225)` を行う） |

- 前処理はアプリ側でリサイズ（またはアスペクト比を保った中央クロップ）してから渡す。**アスペクト比を崩すと画角の推定がずれる**。
- 検証では「アスペクト比で中央クロップしてからバイキュービックでリサイズ」を使った。
- 向きは、画面に正立した画像を渡す（縦持ちなら縦長のモデルを使う）。

### 出力

| 名前 | 型 | 形状（標準モデル） | 値域・意味 |
| --- | --- | --- | --- |
| `points` | MultiArray FP32 | `1×3×504×378`（`1×3×H×W`、チャンネルは x, y, z） | **アフィン不変の点群**。そのままではメートルではない。z は常に正（`exp` 済み）。x, y は画像平面方向 |
| `mask` | MultiArray FP32 | `1×1×504×378` | 有効画素の確率 0〜1（`sigmoid` 済み）。**0.5超を有効**とする。空や遠景などは無効になる |
| `metric_scale` | MultiArray FP32 | `1×1` | メトリックスケール（正の実数）。後処理で深度に掛ける |

出力の解像度は入力と同じ。`MLMultiArray` の `strides` は連続とは限らない（実測では行方向のパディングはなかったが、保証はない）ので、
`MoGeRawOutput.repack` で詰め直してから渡す。

### 座標系

- OpenCV系のカメラ座標: **x右、y下、z前**（光軸方向）。単位はメートル（後処理後）。
- 画像座標は左上原点、行優先。主点は画像中心 `(0.5, 0.5)` に固定、正方画素、歪みなし。
- 「深度」は z-depth（光軸方向の距離）。視線方向の距離（レンジ）が必要なら `|(x, y, z)|` を使う。
- カメラは地面から見て水平とは限らない。**地面平面は点群から別途フィットする**（深度モデルは姿勢を出力しない）。

## 4. 前処理・後処理

### モデル内

- ImageNet正規化。DINOv2の位置埋め込みは入力サイズごとに補間した定数。視野面UVも定数。
- normalヘッドは削除（不要なため）。スケールヘッド（`metric_scale`）、マスクヘッド、点群ヘッドは残してある。

### Swift側（`MoGePostprocess`）

`Packages/RouteDanceCore/Sources/RouteDanceCore/Depth/MoGePostprocess.swift`（純Swift、Foundationとsimdのみ）。

MoGeの公式実装と同じ後処理を行う。

1. `mask > 0.5` の画素を、64×64格子に nearest で間引く。
2. `min_{focal, shift} Σ ‖focal·xy/(z+shift) − uv‖²` を解く（Levenberg-Marquardt）。`uv` は画像対角を1に正規化した視野面座標。
   各 shift で最適な focal は閉形式で求まるので、実質1変数の最適化。
3. `depth = (z + shift) × metric_scale`（`z+shift ≤ 0` とマスク外は NaN）。
4. `focal`（画像対角の半分に対する相対焦点距離）から `fx, fy` を求める。

```swift
public enum MoGeFocalMode { case estimate; case knownHorizontalFOV(Float); case knownIntrinsics(MoGeIntrinsics) }

public struct MoGeRawOutput {
    public init(points: [Float], mask: [Float], metricScale: Float, width: Int, height: Int)
    public static func repack(_ source: UnsafePointer<Float>, shape: [Int], strides: [Int]) -> [Float]
}

public struct MoGeIntrinsics {            // 画像サイズで正規化（fx, cx は幅で、fy, cy は高さで割った値）
    public var fx, fy, cx, cy: Float      // cx = cy = 0.5
    public init(fx: Float, fy: Float, cx: Float = 0.5, cy: Float = 0.5)
    public init(horizontalFOV: Float, aspectRatio: Float)
    public func matrix(width: Int, height: Int) -> simd_float3x3
    public var horizontalFOV: Float { get }; public var verticalFOV: Float { get }
    public func unproject(u: Float, v: Float, depth: Float, width: Int, height: Int) -> SIMD3<Float>
    public func project(_ p: SIMD3<Float>, width: Int, height: Int) -> SIMD2<Float>?
}

public struct MoGeDepthResult {
    public var width, height: Int
    public var depth: [Float]             // メートル、z-depth、行優先。無効画素はNaN
    public var valid: [Bool]
    public var intrinsics: MoGeIntrinsics
    public var shift, focal, metricScale, residualRMS: Float
    public func depthAt(x: Int, y: Int) -> Float?
}

public enum MoGePostprocess {
    public static func recover(_ raw: MoGeRawOutput, focal: MoGeFocalMode = .estimate) throws -> MoGeDepthResult
    public static func recover(points: [Float], mask: [Float], metricScale: Float,
                               width: Int, height: Int, focal: MoGeFocalMode = .estimate) throws -> MoGeDepthResult
}
// 例外: MoGePostprocessError.{invalidShape, tooFewValidPoints, solverFailed}
```

- **内部パラメータが既知**（ARKitの記録、動画メタデータなど）のときは `.knownHorizontalFOV` か `.knownIntrinsics` を渡す。
  shift だけを解くので、画角の誤推定による距離誤差を避けられる。
  モデル入力が元画像の中央クロップ／リサイズなら、**クロップ後の画像に対する値**へ換算して渡すこと（水平画角はクロップで変わる）。
- 処理時間は約0.9ms（M4 Pro、releaseビルド、378×504）。ほぼ無視できる。

テスト: `MoGePostprocessTests.swift`（8件、すべて成功）。Core MLの実出力を72×96に間引いた3枚のフィクスチャを、
公式 `recover_focal_shift`（PyTorch＋scipy）の結果と比較する（focal・shift・画角・深度のプローブ点・有効画素数）。
合成データ（既知の focal/shift）の厳密復元、マスク、`repack` のテストもある。

## 5. 計測結果

環境: M4 Pro（Mac）、macOS 26、coremltools 9.0、torch 2.7.0。入力は固定の乱数画像。
20〜30回の中央値（`cpuOnly` のみ5回）。初回ロード（コンパイル込み）は約5〜6秒。

### レイテンシ（M4 Pro、ms）

| モデル（W×H、トークン） | `.all` | `.cpuAndNeuralEngine` | `.cpuAndGPU` | `.cpuOnly` |
| --- | --- | --- | --- | --- |
| 336×448（768）※速度優先 | 28.2 | **26.8** | — | — |
| **378×504（972）標準** | 45.0 | **36.9** | 39.6 | 99.4 |
| 504×378（972） | 45.3 | **36.8** | — | — |
| 420×560（1200）※公式の最小トークン数 | 57.5 | **48.2** | — | — |
| 378×672 / 672×378（1296） | 64〜65 | **54〜55** | 56〜73 | — |
| 参考: Apple公式 DA-V2 Small F16（518×392、相対深度） | 22.4 | 22.3 | — | — |

- すべて目標（Macで200ms以下）を大きく下回る。
- **`.cpuAndNeuralEngine` のほうが `.all` より速い**（約18%）。`.all` では一部の演算がGPUに回り、デバイス間の転送が増えるため。
  ANEを使う設定として **`.cpuAndNeuralEngine` を推奨**する。

### ANEで動いているか（`MLComputePlan`）

全395演算のうち、`.cpuAndNeuralEngine` では **393演算（99.5%）がNeuralEngine**、残り2演算（`mul` と `cast`、入力側）がCPU。
`.all` では NeuralEngine 372、GPU 21、CPU 2。ANE非対応で落ちている演算はない。
サイズ違いのモデルでも同じ割り当てだった。

### iPhone 15 Pro（A17 Pro）の推定

Apple公式のDA-V2 Smallが、iPhone 15 Pro Maxで約34ms、M1 Maxで約33ms。同じモデルのM4 Proでの実測は22msなので、
**iPhone 15 Pro ≒ M4 Proの1.5倍の時間**とみなして外挿する。実機では未計測で、ANEのスケジューリングや熱で±30%程度ずれうる。

| モデル | M4 Pro 実測（ANE） | iPhone 15 Pro 推定 |
| --- | --- | --- |
| 336×448（768トークン） | 27ms | 約40ms |
| **378×504（972トークン）標準** | 37ms | **約55ms（45〜70ms）** |
| 420×560（1200トークン） | 48ms | 約72ms |
| 378×672（1296トークン） | 54ms | 約80ms |

標準モデルで、目標（5〜10Hz、100ms以下）に対して余裕がある。連続動作時の発熱による性能低下は実機で確認が必要。

### 精度（PyTorch FP32 vs Core ML FP16）

サンプル7枚（歩行者の写真5枚：ロンドン、ブロード通り、プラハのカレル橋、ハンガリー、チュレーン大学、およびMoGe付属の交通・村）。
両方の出力を公式の `recover_focal_shift` で後処理し、有効画素の深度を比べた。

| モデル | 深度AbsRel（平均） | p95 | δ<1.05 | マスク一致 |
| --- | --- | --- | --- | --- |
| 378×504 | **0.31%** | 0.4〜1.0% | 100% | 100% |
| 504×378 | 0.30% | 0.3〜1.3% | 100% | 100% |
| 378×672 / 672×378 | 0.25% / 0.23% | — | 100% | 100% |
| 336×448 / 420×560 | 0.28% / 0.17% | — | 100% | 100% |

- 画角の差は0.1度以下、`metric_scale` の差は1%未満。FP16化による劣化は実用上ない。
- 変換ラッパーは、MoGe公式の `forward` とビット一致する（最大差0）。公式 `infer()`（FP32）とCore ML＋同じ後処理との比較でも、AbsRelは0.2〜0.4%、マスクは100%一致。
- 注意: **これは「PyTorch版との一致度」であり、実世界の真の距離に対する精度ではない**（§6参照）。

## 6. 既知の制約・未解決

1. **実世界のメートル精度は未検証**。真値つきの歩行者データ（LiDAR、巻尺など）での評価は未実施。MoGe-2の論文ではメトリック精度が高いとされるが、
   歩行者までの距離（3〜30m）でどの程度の誤差が出るかは、アプリの記録モード（ARKit＋LiDAR付き）で別途測る必要がある。
2. **iPhone実機のレイテンシは推定**。実機計測は未実施。
3. **スケール曖昧性**: 内部パラメータが不明だと、画角の誤推定が距離誤差になる。ARKitの内部パラメータが取れる場合は `.knownIntrinsics` を使う。
   写真ライブラリの動画では、メタデータ（35mm換算焦点距離など）から画角を求められる場合がある。
4. **ズーム・クロップ**: 動画がデジタルズーム済みだと、画角が変わる。推定モード（`.estimate`）なら追従するが、既知画角を渡す場合は換算が必要。
5. **フレーム間の一貫性なし**: 1フレームずつ独立に推定するので、`metric_scale` と画角がフレームごとに揺れる。
   時間方向の平滑化（`metric_scale`・`focal` の指数移動平均や、地面高さ拘束との統合）はアプリ側の課題。
6. **固定入力サイズ**: 向きとアスペクト比ごとに別モデル（各62MB）を持つ。`EnumeratedShapes` は使っていない
   （位置埋め込みとUVを定数化したため。切り替えが必要なら、モデルを複数読み込むほうが単純）。
7. **遠距離の精度**: 入力が378×504なので、遠くの小さな人物は数画素になる。距離の推定は地面平面との交差（足元レイ）を併用する設計（TECH_SELECTION.md §2.3）のままで良い。
8. **変換時の依存**: torch は 2.7.0 に固定（coremltools 9.0 の検証範囲）。MoGeのコミットは `74fbce0`（v3リポジトリだが、`moge/model/v2.py` を使う）。
9. **Package.swift**: テストのリソースは既存の `resources: [.copy("Fixtures")]` で足りる（変更不要）。
10. サンプル画像（Wikimedia Commons、各ファイルのライセンスは個別）は `Tools/ModelConversion/out/samples/`（`.gitignore` 済み）にあり、リポジトリには含めない。
    フィクスチャは生の出力値のみで、元画像は含まない。

## 付録: サンプル画像の取得

```sh
# 検索: Wikimedia Commons API（filetype:bitmap pedestrians street crowd）で見つけた画像を、
# 1280px幅のサムネイルで取得した。User-Agent の指定が必要。
curl -sL -A "route-dance-research/1.0 (local test)" -o out/samples/london_portrait.jpg \
  "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/010_London_pedestrians_-_Neal_Street_in_Covent_Garden%2C_London_UK.jpg/1280px-010_London_pedestrians_-_Neal_Street_in_Covent_Garden%2C_London_UK.jpg"
```
