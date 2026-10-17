# 技術選定

> ステータス: **確定（v1）**。§11に決定事項
> 調査日: 2026-10-17
> 関連: [SPEC.md](SPEC.md)

## 0. 結論（TL;DR）

> 2026-10-17のレビューで確定した内容を反映済み（§11に決定事項の一覧）。

| レイヤ | 採用 | 代替 / 将来 |
| --- | --- | --- |
| 言語・UI | Swift 6 / SwiftUI。iOS 27とmacOS 27の2つのアプリターゲットでコードを共有 | — |
| 深度・空間 | **単眼メトリック深度 MoGe-2 ViT-S（MIT、35M）をCore ML化**。カメラの画角も推定するので、内部パラメータが不明な動画でも使える | Depth Anything V2 Metric Small、Depth Anything 3 Small（Apache-2.0） |
| 地面 | **深度の点群から地面平面をRANSACで推定**（カメラ高さとカメラの傾きが得られる） | 深度がないときは「高さ1.45m＋重力方向」を仮定 |
| 自己位置 | **画像オドメトリ**（地面上の点をオプティカルフローで追い、俯瞰座標でSE(2)をRANSAC推定）。ライブも動画も同じ処理。ライブではCoreMotionのジャイロと重力で補う | 比較用にARKitの姿勢を使うモード（未定） |
| 人物検出 | **Vision `DetectHumanRectanglesRequest`**（OS標準、iOS/macOS共通） | YOLOX（Apache-2.0）/ MIT版YOLOをCore ML化 |
| 人物の位置 | **足元レイと地面の交点**と**深度の中央値**を分散で重み付けして統合。足元が画面外なら頭の位置と身長の事前分布を使う | — |
| 追跡 | **ByteTrack方式を自前Swift実装**（地面座標のカルマンフィルタ＋ハンガリアン法で2段階マッチング） | OC-SORTの再更新を追加 |
| 軌道予測 | **等速度モデル(CVM)＋決定論的な多峰サンプル**（Phase 1） | 学習モデル（EqMotion / MoFlow / Trajectron++、すべてMIT）をPhase 2で比較 |
| 予測ホライズンN | **最接近時刻(CPA)ベースの可変N**（これのみ） | — |
| ゴール | **端末が向いている方向の、地面上で見える最も遠い点** | 地図で指定した目的地へ、道のりに沿って案内（`GoalProvider`を差し替える） |
| 経路計画 | **現在速度で約5秒先までのサンプリング型経路探索＋サンプルベースの衝突確率** | MPPIでの局所改善、PGIF型の異方性リスク場 |
| 減速区間 | **パス-速度分解（ST-graph上のDP）** で速度プロファイルを求め、緑・黄・赤で表示 | — |
| 描画 | Metal（`MTKView`）でカメラ映像を描き、デバッグ時は白っぽく加工。オーバーレイはSwiftUI `Canvas` | — |
| 動画入力 | **普通の動画**（写真ライブラリ / Macではファイル）を、ライブと同じパイプラインで処理する | — |
| Mac | 同じUI・同じアルゴリズムで動画を処理。コアは`swift test`でヘッドレスに検証 | — |
| プロジェクト管理 | XcodeGen（`project.yml`をGit管理）＋ローカルSwift Package | — |

**方針の要点**: 空間認識をすべて「画像だけ」から行う（深度・地面・自己位置）。そうすることで、ライブ映像と事前に撮影した普通の動画が**同じ処理経路**を通る。LiDARとARKitの深度は使わない。

---

## 1. 調査方法と信頼度

- 調査ワークフローでWeb検索→一次情報の取得→主張ごとの3票の反証検証を実施。77件の主張を抽出し、上位25件を検証して24件が残り、1件が反証された。
- 検証の途中でWebSearchがAPIエラーになり、検出・深度・Mac対応の領域は検証が不十分だった。この部分は次の方法で**直接確認**した。
  - Apple公式ドキュメントのJSONで、APIの対応プラットフォームを確認
  - GitHub API / HuggingFace APIで、ライセンスと最終更新日を確認
- 下の表で「既知文献」と書いたものは、確立した古典的研究で、今回はWebで再検証していない。

| 印 | 意味 |
| --- | --- |
| ✅ | 今回、一次情報で確認済み |
| 📚 | 既知文献（今回は未再検証） |
| ⚠️ | 未検証。実機での検証が必要 |

---

## 2. 空間認識（画像のみから）

### 2.0 方針の変更（2026-10-17）

- 当初はLiDARとARKitを主軸にしていたが、次の2点から**画像だけで空間を推定する**方針に変えた。
  - LiDARは精度が足りない。
  - 事前に撮影した普通の動画でも、同じ処理で動かしたい。
- 深度・地面・自己位置の3つをすべて画像から推定する。ライブ映像と動画が同じ処理経路を通るので、評価結果がそのままライブの性能を表す。

### 2.1 単眼メトリック深度 ✅

| 候補 | ライセンス | 規模 | 出力 | 評価 |
| --- | --- | --- | --- | --- |
| **MoGe-2 ViT-S**（CVPR'25 Oral系、`Ruicheng/moge-2-vits-normal`） | ✅ MIT（DINOv2部分はApache-2.0） | 35M | メトリック点群、深度、**カメラFOV**、法線 | **採用**。画角も推定するので、焦点距離が不明な動画でも使える。Core ML化は自前（⚠️ 変換と速度は検証中） |
| MoGe-2 ViT-B | ✅ MIT | 104M | 同上 | 精度を優先するときの候補 |
| Depth Anything 3 Small / Base | ✅ Apache-2.0 | 80M / 120M | 相対深度、姿勢 | メトリック版はLargeのみ（350M）で重い |
| Depth Anything V2 Metric Outdoor Small | ⚠️ HF上にライセンスタグなし（元のSmallはApache-2.0） | 25M | メトリック深度 | Plan B。画角は推定しない |
| apple/coreml-depth-anything-v2-small | ✅ Apache-2.0 | 25M | **相対**深度 | 変換済みで速い（iPhone 15 Pro Maxで約34ms）。スケールは地面から復元する必要あり |
| Metric-Video-Depth-Anything-Small | ✅ Apache-2.0 | — | メトリック、時間方向に安定 | 動画向けで有望。Core ML化は ⚠️ |
| Depth Pro | ✅ apple-amlr（研究用途） | 大 | メトリック | **不採用**（ライセンス） |
| UniDepth / CUT3R / MoGe以外の多くのモデル | ✅ ライセンス表記なし、または不明確 | — | — | **不採用** |
| DA3 Nested Giant | ✅ CC-BY-NC-4.0 | — | — | **不採用**（非商用） |

- 深度は5Hz程度で推定する。間のフレームは、自己位置推定の結果で前回の深度をずらして使う。
- 単眼深度の絶対スケールは誤差が数%〜十数%ある。そのため、**地面平面から得たカメラ高さ**を時間方向に平滑化し、スケールを安定させる補正に使う。

### 2.2 地面平面とカメラ姿勢

- 深度の点群の画面下半分からRANSACで平面を当てはめ、地面の法線（＝重力方向の推定値）とカメラ高さhを得る。
- 法線の向きは、ライブではCoreMotionの重力ベクトルで照合・補正する（動画では使えないので、画像だけで推定する）。
- hは指数移動平均で平滑化する。外れ値（段差、人で地面が隠れる）は棄却する。妥当な範囲は1.0〜1.8m。
- 地面座標系: 原点はカメラ直下の地面、Y軸は上向き、Z軸はカメラの前方を地面に投影した向き。

### 2.3 自己位置（ユーザーの移動）

- **画像オドメトリ（自前実装）**:
  1. 地面マスク（平面からの距離が小さい画素）上の特徴点を、Visionのオプティカルフロー（`TrackOpticalFlowRequest`、✅ iOS 18+/macOS 15+）、またはLucas-Kanadeで追跡する。
  2. 各点を深度と地面平面で**俯瞰座標 (x, z)** に変換する。
  3. 前後のフレーム間の剛体変換SE(2)（回転θと並進）をRANSAC＋最小二乗で推定する。
  4. 人物の枠の内側の点は除外する（他歩行者の動きを自分の動きと誤認しないため）。
- 回転は、ライブではCoreMotionのジャイロを優先し、画像推定と融合する。
- ユーザー速度は、並進を1〜1.5秒の窓で平滑化して求める。歩行の周期的な揺れは平滑化で消す。
- ライブ映像は`AVCaptureSession`で取り、ARKitは使わない。比較用にARKitの姿勢を使うモードは必要になったら検討する。

### 2.4 人物検出

| 候補 | ライセンス | iOS / macOS | 評価 |
| --- | --- | --- | --- |
| **Vision `DetectHumanRectanglesRequest`** | OS標準 | ✅ 両方 | **採用**。全身・上半身を検出。遠くの小さな人物の検出率は ⚠️ 要検証 |
| Ultralytics YOLO11 / YOLOv8 / v10 / v12 | ✅ AGPL-3.0 | — | **不採用** |
| YOLOX | ✅ Apache-2.0 | ⚠️ | Plan B |
| MultimediaTechLab/YOLO（YOLOv9系のMIT再実装） | ✅ MIT | ⚠️ | Plan B |
| RF-DETR / D-FINE / RT-DETR | ✅ Apache-2.0 | ⚠️ | 精度が足りないときの候補 |

検出器は`PersonDetector`プロトコルの裏に隠し、差し替えられるようにする。

### 2.5 人物の地面位置

1. **足元レイ**: 枠の下端中央から光線を飛ばし、地面平面と交差させる。枠が画面下端に接している（足元が切れている）ときは使わない。
2. **深度**: 枠の中央の縦帯の深度の中央値に、体の厚みの半分（約0.15m）を足す。
3. **身長の事前分布**: 枠の上端（頭）と、平均身長1.65m±0.1mから推定する（足元が切れているときの補助）。
4. 各方法の分散で重み付けして統合する。距離が遠いほど、足元レイの分散が大きくなる（角度誤差が距離の2乗で効く）。

### 2.6 追跡（MOT）

- Swift製の成熟したByteTrack/OC-SORT実装は見つからなかった。元実装はいずれも ✅ MIT。
- **自前で実装する**:
  - 状態は**地面座標**上の位置・速度（定速カルマンフィルタ）。
  - 毎フレーム、自己位置の変化（SE(2)）で全トラックを現在の座標系に変換する。
  - マッチングはByteTrack方式で、高スコア検出→低スコア検出の2段階。コストは地面距離のマハラノビス距離と画像IoUの組み合わせ。割り当てはハンガリアン法。

## 3. 軌道予測

### 3.1 学習モデルの現状 ✅

ETH/UCY平均（minADE/FDE、20サンプル、単位m、作者の自己申告）:

| モデル | ADE/FDE | ライセンス | 規模・速度 | 備考 |
| --- | --- | --- | --- | --- |
| MoFlow（CVPR 2025） | 0.20/0.32（IMLEの1ステップ版は0.21/0.33） | ✅ MIT（2026-05更新） | 1ステップ版は教師の約100倍速。絶対レイテンシは非公開 | 「オンデバイスのリアルタイムに適する」という主張は**検証で反証された**（根拠がない） |
| SingularTrajectory（CVPR 2024） | 0.21/0.32 | ✅ ライセンス表記が不明確 | 拡散モデル | 要注意 |
| LED（CVPR 2023） | 0.21/0.33 | ✅ **LICENSEファイルなし** | 約6.6M＋4.6Mパラメータ | 規模は魅力的だがライセンスがなく使えない |
| EqMotion（CVPR 2023） | 0.21/0.35 | ✅ MIT | 軽量なGNN | **Core ML化の第1候補** |
| Trajectron++（ECCV 2020） | — | ✅ MIT（2023年以降は更新停止） | GRUとグラフ | オンラインモードあり |
| AgentFormer（ICCV 2021） | arXiv更新版の数値を使う必要あり（正規化バグ） | ✅ MIT | Transformer | — |

わかったこと:

- **精度はほぼ横並び**（差は数cm）。選ぶ基準は精度より**ライセンス、規模、Core ML化のしやすさ、ego視点のノイズへの強さ**。
- **どのリポジトリにもCore ML/ONNX変換やレイテンシの記載がない**。変換と実機速度の測定は自前で行う必要がある（⚠️）。
- ETH/UCYは**俯瞰（三人称）視点**のデータ。iPhoneからのego視点には、検出・追跡の欠け、オクルージョン、狭い画角が加わる。この問題はT2FPV（ETH/UCYから一人称視点を合成）が扱っているが、ライセンス表記がなく、合成画像なので実写との差がある。
- 📚 Schöller et al.（RA-L 2020）"What the Constant Velocity Model Can Teach Us About Pedestrian Motion Prediction" は、**等速度モデル(CVM)が多くの深層モデルと同等以上**になると報告している。観測ノイズが大きいego視点では、単純なモデルの方が頑健なことが多い。
- ✅ 2607.09192（実ロボットの対面試験）でも、**単純な場面では学習型予測の上積みが小さい**という結果が出ている。

### 3.2 方針

**Phase 1は物理ベースで作り、Phase 2で学習モデルを同じ評価基盤で比較する。**

- Phase 1の予測器 `CVMPredictor`:
  - 追跡器が推定した速度で外挿する。
  - 不確かさは時間とともに広げる（σ(t) = σ₀ + k·t。進行方向とその直交方向で別々の値）。
  - 多峰性は、向きと速さを摂動したK本（例: 20本）のサンプル軌道で表す（CVM-S方式）。
  - 停止している人は等方的に拡散させる。
- 予測器の出力は**重み付きサンプル軌道の集合**に統一する。CVM-Sも学習モデル（K個の未来を出す）も同じ形で出力できるので、後段の計画と描画が予測器に依存しない。
- Phase 2: EqMotion → MoFlow（1ステップ版） → Trajectron++の順でCore ML化を試み、ADE/FDE、衝突率、推論時間で比べる。
  - 学習済み重みと学習データのライセンス（ETH/UCYは独自条件、nuScenesは非商用など）は別途確認が必要。
- 他歩行者がユーザーを避けてくれることは**仮定しない**（安全側に倒す）。

### 3.3 予測ホライズン N

仕様の初期案「N = 距離 / ユーザー速度」には次の問題がある。

- **対向してくる人**: 実際の接近はもっと早い。相対速度は v_user + v_ped なので、Nが長すぎる（害は小さい）。
- **同じ方向に歩いている人**: 追いつくのはもっと遅い。必要な時間は d / (v_user − v_ped) なので、**Nが短すぎて危険**。
- **ユーザーが停止したとき**: Nが無限大に発散する。

**提案: 最接近時刻(CPA)ベースの可変ホライズン**

```
p = 他歩行者の位置 − ユーザー位置, v = 他歩行者の速度 − ユーザー速度（相対速度）
t_cpa = max(0, −(p·v) / |v|²)
N_i = clamp(t_cpa + τ, N_min, N_max)      例: τ = 1.0s, N_min = 1.0s, N_max = 6.0s
|v| が十分小さいとき: N_i = clamp(d / max(v_user, v_floor), N_min, N_max)
```

- これは仕様の考え方（近い人は短く、遠い人は長く）を、相対速度を考慮する形に一般化したもの。衝突回避の分野で標準的なTTC/CPAの考え方に沿っている（📚 Karamouzas et al., PRL 2014「歩行者の相互作用はTTCのべき乗則に従う」、📚 ORCA / Velocity Obstacles）。
- N_maxは予測の信頼限界で決める。σ(t)が大きくなりすぎると予測が意味を持たなくなるためで、ETH/UCYの標準である4.8秒も参考にする。
- 関連研究として、✅ 2603.00507（2026年、プレプリント）が、社会的文脈に応じてMPCのホライズンを学習でオンラインに選ぶ手法を提案している。重いのでPhase 1では使わない。
- 実装: 衝突評価は全員について計画ホライズン T_plan（5秒）まで行う（CVMなら軽い）。N_iは**表示範囲と影響範囲**に使う。
- 決定: CPA方式のみを実装する（d/v方式は残さない）。

---

## 4. 経路計画

### 4.1 要件の整理

- ユーザーの**現在の歩行速度 v で辿れる経路**を出す → 速度は固定し、**向き（曲率）の列だけを探索**する。
- 表示する長さは**約5秒先まで**（T_plan = 5s。経路長は v·T_plan）。停止中も経路が見えるよう、計画に使う速度には下限 v_min = 0.5 m/s を設ける。
- それでも避けられない場合だけ減速する → 減速区間を黄〜赤で示す。
- ゴール（v1）: **端末が向いている方向の、地面上で見える最も遠い点**。
  - カメラの前方を地面に投影した方向に沿って、地面マスクの最遠点を探す。
  - 上限は30m。見つからないときは、その方向に30m先の点とする。
  - 将来は地図での目的地指定に差し替える（`GoalProvider`プロトコル）。

### 4.2 アルゴリズム（Phase 1）

1. **候補の生成**: 速度vで、T_plan後までの候補経路を生成する。
   - 前半と後半で曲率を変える2段の円弧（一度曲がってから戻る）。旋回レートの上限付き。
   - 数は数百本程度。DWA / state latticeの考え方（📚）。
2. **衝突確率**: 各候補について、各他歩行者のサンプル軌道kとの距離が R（体の半径＋パーソナルスペース、例: 0.6m）を下回るかを時刻ごとに評価する。
   ```
   p_i = Σ_k w_k · σ((R − min_t |x(t) − s_ik(t)|) / ε)    （微分可能なソフト版）
   P_safe = Π_i (1 − p_i)                                  （他歩行者は互いに独立と仮定）
   ```
3. **コスト**: J = w_risk·(1−P_safe) + w_goal·(終点からゴールへの距離の減少量に対するペナルティ) + w_smooth·|前回の計画との差|
   - 前回の計画との差の項はヒステリシスとして働き、矢印のチラつきを抑える。
4. **減速が必要な場合**（最良の候補でも P_safe < 閾値）: 上位M本の経路の形を固定し、**ST-graph**（経路上の距離 s × 時刻 t）上で動的計画法を解いて、速度プロファイル v(s) ≤ v_current を求める（📚 Kant & Zucker 1986のパス-速度分解。自動運転のBaidu Apollo EM Plannerでも使われている方式）。
   - 色は v(s)/v_current で決める: 1.0 = 緑、〜0.6 = 黄、〜0.2以下 = 赤。
5. **改善（Phase 2）**: MPPI（📚 Williams et al. 2016）で最良候補の周辺を局所的に最適化する。✅ PGIF（2608.08323、プレプリント）は、各他歩行者を進行方向に伸びた異方性ガウスのリスク場としてMPPIのコストに入れる手法で、後から導入を検討できる。

### 4.3 可視化に直結する量

- **推奨経路の線**: 色は速度比（緑・黄・赤）。
- **コンパス矢印**: 推奨経路上で前方 L = v·1.5s の点への方位を、端末の向き（カメラの前方を地面に投影した方向）を基準にして表示する。360°回転する。
- **衝突しない確率のグラデーション（デバッグ時）**: 地面グリッドの各セルcに、ユーザーがそこへ到達する時刻 t_c = 距離/v を割り当て、その時刻にc付近に誰かがいる確率を色で示す。これは「今の速度でそこへ行ったらぶつかるか」を表すので、時刻付きの占有グリッドになる。あわせて全候補経路も P_safe の色で薄く描く。

---

## 5. 描画・UI

- **カメラ映像**: `MTKView`に描画する。デバッグ時はフラグメントシェーダでコントラストを下げ、白を混ぜて白っぽくする（1パスなのでほぼ無負荷）。
- **地面のオーバーレイ**（経路、ヒートマップ、予測経路）: 地面座標の点を、推定した内部パラメータと地面平面を使って画面に投影し、SwiftUIの`Canvas`で描く。重くなったらMetal化する。
  - **RealityKitの`ARView`は使わない**。`ARSession`が前提なので、動画とMacで同じUIにできないため。
- **HUD（上部に常時表示）**: ユーザー速度、FPS、検出数、追跡数、各処理の時間、自己位置推定の状態、カメラ高さ、入力ソース。
- **ドロワー**: 左下のハンバーガーメニューを押すと、下からせり上がるシート。中身は「デバッグモード（デフォルトON）」と「入力ソース（カメラ / 動画）」。

---

## 6. 動画入力・評価・Mac対応

### 6.1 アーキテクチャ

```
FrameSource (protocol)
 ├─ CameraFrameSource   … iOSのライブ入力（AVCaptureSession＋CoreMotion）   #if os(iOS)
 └─ VideoFileSource     … 写真ライブラリ / ファイルの普通の動画（AVAssetReader）  iOS / macOS
        ↓  Frame { 画像, 時刻, 向き, 重力?（ライブのみ）, ジャイロ?（ライブのみ） }
Perception: 深度(MoGe-2) / 人物検出(Vision) / オプティカルフロー
        ↓
Core: 地面推定 → 自己位置推定 → 人物の地面位置 → 追跡 → 予測 → 計画   ← 純Swift、swift testで検証
        ↓
Renderer（Metal＋SwiftUI Canvas）/ HUD / ドロワー                     ← iOSとmacOSで共通
```

- ライブ映像はARKitではなく`AVCaptureSession`で取る。ARKitを使わないことで、ライブと動画の処理を同一にできる。
- 重力とジャイロはライブでだけ得られる追加情報で、なくても動く設計にする。

### 6.2 写真ライブラリの動画に同じUIを重ねられるか → **できる**

- 深度・地面・自己位置をすべて画像から推定するので、普通の動画でもライブと同じ処理になる（記録モードは不要になった）。
- 動画のメタデータに焦点距離があれば内部パラメータの初期値に使い、なければMoGe-2の画角推定を使う。
- 再生は実時間（処理が追いつかなければフレームを捨てる）と、全フレーム処理（評価用）を選べる。

### 6.3 Macで動かせるか → **できる**

- ✅ Vision（人物検出・オプティカルフロー）、Core ML、Metal、SwiftUI、AVFoundationはmacOSでも使える。
- macOSアプリでは、動画ファイルを開くかドラッグ＆ドロップで読み込み、iPhoneと同じUIで再生する。
- `RouteDanceCore`は`swift test`でヘッドレスに検証できる。

### 6.4 評価指標

| 対象 | 指標 | 正解データ |
| --- | --- | --- |
| 予測 | ADE/FDE（ホライズン別）、minADE_K | 動画全体を処理した後の、**前後方向に平滑化した追跡結果**を疑似正解にする。ETH/UCYでは公式の正解 |
| 追跡 | IDスイッチ数、トラックの寿命 | 目視でのラベル付け（少量） |
| 計画 | 他歩行者との最小距離、予測上の衝突率、推奨方向の揺れ（°/s）、減速率 | 動画 |
| 性能 | 各処理の時間、FPS、端末の温度状態 | 実機 |

- ETH/UCYを読み込むツールを用意し、予測器の実装が論文の値（例: CVMのADE）を再現するかをローカルで確認する。

---

## 7. 開発環境・プロジェクト構成

- Xcode / Swift 6（strict concurrency）/ Swift Testing。
- **Deployment target: iOS 27.0 / macOS 27.0**（アプリ）。
  - 2026-10-17時点の手元はXcode 26.6（iOS SDK 26.5）とmacOS 26.5。iOS 27のSDKとmacOS 27を入れるまでは、`project.yml`の`DEPLOYMENT_IOS` / `DEPLOYMENT_MACOS`を一時的に26.0にしてビルド確認する。
  - `RouteDanceCore`パッケージは、ホスト上で`swift test`できるよう下限をiOS 26 / macOS 26にしておく（27の専用APIは使わない）。
- 実機: iPhone 15 Pro。
- **XcodeGen**（`project.yml`）でプロジェクトを生成し、`.xcodeproj`はGit管理しない。

```
route-dance/
├─ project.yml                     # XcodeGen
├─ App/
│  ├─ Shared/                      # UI（HUD, Drawer, Overlay, Compass）, Pipeline, VideoFileSource
│  ├─ iOS/                         # CameraFrameSource, Info.plist
│  └─ macOS/
├─ Packages/RouteDanceCore/
│  ├─ Sources/RouteDanceCore/      # 純Swift: Geometry, Ground, Odometry, Tracking, Prediction, Planning
│  ├─ Sources/RouteDancePerception/# Vision / Core ML / Metalのラッパー
│  └─ Tests/
├─ Models/                         # .mlpackage（Git管理外）
├─ Tools/ModelConversion/          # Core ML変換スクリプト(Python)
└─ docs/
```

- 外部依存は**なし**（Apple純正のフレームワークと自前実装のみ）。Core MLモデルは変換スクリプトで生成し、`.gitignore`に入れる。

---

## 8. マイルストーン

| # | 内容 | 完了条件 |
| --- | --- | --- |
| M0 | Git、ドキュメント、XcodeGen、空のアプリ（iOS/macOS）、Coreパッケージ | iOSとmacOSでビルドが通る |
| M1 | Coreアルゴリズム（地面、オドメトリ、追跡、CVM予測、CPAホライズン、計画）とユニットテスト | `swift test`が通る |
| M2 | 深度モデルのCore ML化と後処理 | Macで推論が動く |
| M3 | UIの骨組み（映像、デバッグ加工、HUD、ドロワー、コンパス、オーバーレイ） | Macで動画を再生してUIが出る |
| M4 | パイプラインの接続（検出→位置→追跡→予測→計画→描画） | Macで動画から推奨経路が出る |
| M5 | iOSのライブカメラ、写真ライブラリからの動画選択 | 実機で動く（iOS 27 SDKの導入後） |
| M6 | 評価（疑似正解、指標） | 評価表 |
| M7 | 学習型予測器のCore ML化と比較 | 評価表 |

---

## 8.1 進捗（2026-10-17）

| # | 状態 | メモ |
| --- | --- | --- |
| M0 | 完了 | XcodeGen、`scripts/generate.sh`、iOS/macOSの2ターゲット、Coreパッケージ |
| M1 | 完了 | `swift test` で34件が通る（合成シーンでの地面・位置推定・追跡・予測・計画・パイプライン全体） |
| M2 | 完了 | MoGe-2 ViT-S を Core ML 化（M4 ProのANEで約37ms）。後処理はSwift |
| M3 | 完了 | 映像の白っぽい加工、HUD、ドロワー、コンパス、オーバーレイ。Macで動画を再生して確認済み |
| M4 | 完了（要調整） | 検出→位置→追跡→予測→計画→描画がつながった。パラメータは実写の歩行動画で調整が必要 |
| M5 | 実装済み・実機未確認 | iOSのライブカメラと写真ライブラリの動画。シミュレータで起動のみ確認 |
| M6, M7 | 未着手 | — |

実装上の補足:

- オプティカルフローは、VisionのAPIではなく**自前のピラミッド型Lucas-Kanade**（`SparseOpticalFlow`）にした。疎な点の追跡だけで済み、iOS/macOSで完全に同じ結果になるため。
- 深度の推論とモデルの読み込みは、フレーム処理を止めないよう別タスクで行う（約5Hz）。
- 計算の重い数値処理は、Debugビルドでも`-O`で最適化する（`Package.swift`の`optimizeInDebug`）。

## 9. 未決事項

- 地図による目的地指定（将来）: 地図SDK、経路探索、地図と映像の位置合わせ（GPSとコンパスの精度）。
- 計画のパラメータ（R、T_plan、候補数、色の閾値）は動画で調整する。
- 実写の歩行動画での検証（今は静止画をズームしただけの合成動画でしか確認していない）。
- 画像オドメトリの精度（速度表示が実際の歩行速度と合うか）。
- MoGe-2のメトリック距離の実精度（巻尺で測った地点を写した動画で確認する）。

## 10. リスク

- **歩きスマホの安全性**: 画面を見ながら歩く使い方そのものにリスクがある。注意表示などの扱いは別途検討する。
- **単眼深度のスケール誤差**: 数%〜十数%ずれる。地面から得たカメラ高さで補正するが、坂・階段・地面が見えない混雑では劣化する。
- **画像オドメトリのドリフト**: 床の模様が少ない、人が多い、急な回転、などで劣化する。経路は5秒先までの局所的なものなので、長期のドリフトは問題になりにくい。
- **ANEの負荷と熱**: 深度（5Hz）と検出（10〜15Hz）を常時動かす。解像度と頻度は実機で調整する。
- Visionの人物検出の遠距離での性能 ⚠️ → 足りなければYOLOX等に差し替える。
- ego視点の観測ノイズ（オクルージョン、画角外へのフレームアウト）が予測精度を大きく下げる。追跡の安定化が最重要。
- 学習モデルの重みとデータセットのライセンス（商用で使えるかどうか）。

## 11. 決定事項（2026-10-17のレビュー）

1. ブランチは`master`。
2. 対応OSは**iOS 27 / macOS 27**。
3. 軌道予測は、Phase 1を物理ベース(CVM)とし、Phase 2で学習モデルを比較する。
4. XcodeGenを使う。
5. ゴールは**端末が向いている方向の最も奥**。将来は地図で指定した目的地へ、道のりに沿って案内する。
6. 予測ホライズンは**CPA方式のみ**。
7. 記録モードは**作らない**。普通の動画で動かす。
8. 推奨経路は、歩行速度に合わせて**約5秒先まで**表示する。
9. LiDARは精度が足りないので、**画像からの距離推定**を主軸にする。

## 12. 出典

一次情報（今回確認したもの）:

- 軌道予測: [MoFlow](https://moflow-imle.github.io/) / [arXiv 2503.09950](https://arxiv.org/abs/2503.09950)、[EqMotion](https://github.com/MediaBrain-SJTU/EqMotion)、[LED](https://github.com/MediaBrain-SJTU/LED) / [arXiv 2303.10895](https://arxiv.org/abs/2303.10895)、[SingularTrajectory](https://github.com/InhwanBae/SingularTrajectory)、[EigenTrajectory](https://github.com/InhwanBae/EigenTrajectory)、[Trajectron++](https://github.com/StanfordASL/Trajectron-plus-plus)、[AgentFormer](https://github.com/Khrylx/AgentFormer)、[T2FPV](https://github.com/cmubig/T2FPV) / [arXiv 2209.11294](https://arxiv.org/abs/2209.11294)
- 可変ホライズン・計画: [arXiv 2603.00507](https://arxiv.org/abs/2603.00507)、[arXiv 2607.09192](https://arxiv.org/abs/2607.09192)、[arXiv 2608.08323 (PGIF)](https://arxiv.org/abs/2608.08323)
- 深度（追加調査）: [MoGe](https://github.com/microsoft/MoGe)（MIT）/ [moge-2-vits-normal](https://huggingface.co/Ruicheng/moge-2-vits-normal)、[Depth-Anything-3](https://github.com/ByteDance-Seed/Depth-Anything-3)（Small/BaseはApache-2.0、Nested GiantはCC-BY-NC）、[Metric3D](https://github.com/YvanYin/Metric3D)（BSD-2）、[Prompt Depth Anything](https://github.com/DepthAnything/PromptDA)、[Distill-Any-Depth](https://github.com/Westlake-AGI-Lab/Distill-Any-Depth)（MIT）
- 深度: [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small)、[Depth-Anything-V2](https://github.com/DepthAnything/Depth-Anything-V2)、[Video-Depth-Anything](https://github.com/DepthAnything/Video-Depth-Anything)、[apple/DepthPro](https://huggingface.co/apple/DepthPro)
- 検出・追跡: [Ultralytics License](https://www.ultralytics.com/license)、[YOLOX](https://github.com/Megvii-BaseDetection/YOLOX)、[MultimediaTechLab/YOLO](https://github.com/MultimediaTechLab/YOLO)、[RF-DETR](https://github.com/roboflow/rf-detr)、[ByteTrack](https://github.com/FoundationVision/ByteTrack)、[OC-SORT](https://github.com/noahcao/OC_SORT)、[BoT-SORT](https://github.com/NirAharon/BoT-SORT)
- Apple: [ARSession](https://developer.apple.com/documentation/arkit/arsession)、[ARFrame.sceneDepth](https://developer.apple.com/documentation/arkit/arframe/scenedepth)、[ARBodyTrackingConfiguration](https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration)、[DetectHumanRectanglesRequest](https://developer.apple.com/documentation/vision/detecthumanrectanglesrequest)、[TrackOpticalFlowRequest](https://developer.apple.com/documentation/vision/trackopticalflowrequest)、[CMPedometer](https://developer.apple.com/documentation/coremotion/cmpedometer)

既知文献（📚、今回は未再検証）:

- Schöller et al., "What the Constant Velocity Model Can Teach Us About Pedestrian Motion Prediction", RA-L 2020
- Karamouzas, Skinner, Guy, "Universal Power Law Governing Pedestrian Interactions", PRL 2014
- van den Berg et al., "Reciprocal n-Body Collision Avoidance (ORCA)", 2011
- Kant & Zucker, "Toward Efficient Trajectory Planning: The Path-Velocity Decomposition", IJRR 1986
- Williams et al., "Aggressive Driving with Model Predictive Path Integral Control (MPPI)", ICRA 2016
- Fox, Burgard, Thrun, "The Dynamic Window Approach to Collision Avoidance", 1997

## 13. 第2回の改良（2026-10-17、実写の歩行動画を見たフィードバック）

### 13.1 要望と原因

| 要望 | 原因（調べてわかったこと） |
| --- | --- |
| 経路の修正が早すぎて、いきなり変わる | 毎フレーム（30fps）、全候補の中からコスト最小のものを選び直していた。前回の計画を引き継いでおらず、切り替えのヒステリシスもなかった |
| 全員から一番離れた経路が選ばれる。流れに乗りたい | リスク項が `6·(1−P_safe)` の線形で、安全な領域でも離れるほど得をしていた。さらに予測の不確かさが等方的（σ=0.15+0.12t）で、横に1m離れて並走していても、5秒後の衝突確率が約0.3になっていた |
| 人物検出が抜ける | Visionの `upperBodyOnly` を `false` にしていた。既定は `true` で、`false` だと全身が映っていないと検出されない。実動画3本で比べると、0件のフレームが `false` で47/130/90、`true` で12/66/5（各150フレーム中） |
| 抜けたフレームでも人を避けたい | 計画に使うのは「確定済み、または見失って0.5秒以内」のトラックだけだった。またカルマンフィルタのQがフレームレートに依存していて、見失い中の不確かさが過小だった |
| 経路の起点がちょこちょこ動く | 起点はカメラ直下の地面（画面外）。描画で画面外の点を捨てていたため、最初に画面に入る点が起点に見え、地面の推定（俯角）の揺れで動いて見えていた |
| 予測地点が見えない、ボックスがない人がいる | 予測の表示を「確定済みで5回以上検出」に絞っていた。枠は位置推定できた検出だけ描いていた |

### 13.2 採用した手法

- **計画の時間的一貫性**（Apollo EM Planner [arXiv:1807.08048](https://arxiv.org/abs/1807.08048) の前回計画の引き継ぎ、Smooth MPPI [arXiv:2112.09988](https://arxiv.org/abs/2112.09988)）
  - 前回の計画を新しい予測で評価し直し、十分に良い候補があるときだけ切り替える（ヒステリシスと最小保持時間）。
  - 曲率は時間方向にローパスをかけ、候補は現在の曲率から連続に始める。
- **人の歩行の滑らかさ**（Arechavaleta et al. 2008 [doi:10.1109/tro.2008.915449](https://doi.org/10.1109/tro.2008.915449)）
  - 人の歩行軌道は曲率の変化率を最小にする、という知見に合わせ、曲率変化率の上限と速度に応じた曲率の上限を置く。
- **安全なら滑らかさ優先**（チャンス制約計画 Blackmore et al. 2011 [doi:10.1109/tro.2011.2161160](https://doi.org/10.1109/tro.2011.2161160)）
  - リスクを閾値ε付きのヒンジにした。閾値以下の候補は「安全」として、その中で滑らかさとゴールへの進み具合で選ぶ。
- **予測の不確かさを異方性に**
  - 進行方向に長く、横に短くした。同じ方向に歩く人のすぐ横を抜ける経路が「安全」になる。
- **見失いへの対処**（ByteTrack [arXiv:2110.06864](https://arxiv.org/abs/2110.06864)、OC-SORT [arXiv:2203.14360](https://arxiv.org/abs/2203.14360)）
  - 確定済みトラックは、削除されるまで外挿した位置で回避対象に含める。
  - 削除までの時間は、近い人で2秒、遠い人で1秒。位置の標準偏差が1.5mを超えた場合も削除する。
  - Qは連続白色雑音加速度モデル。見失い時間Tで、位置の分散がおよそT³で増える。
  - 再検出したときは、最後の観測から速度を推定し直す（OC-SORTのObservation-centric Re-Update）。
  - 近い人（4m以内）は1回の検出で確定する。
- **深度からの障害物**（Stixel World、Badino et al. 2009 [doi:10.1007/978-3-642-03798-6_6](https://doi.org/10.1007/978-3-642-03798-6_6)、ROS `depthimage_to_laserscan`）
  - 地面からの高さで障害物の画素を判定し、方位ビンごとの最短距離を取る。
  - 全身が映っていない近くの人も、障害物として避けられる。
- **超広角カメラ**
  - `.builtInUltraWideCamera` を単体で使う。仮想デバイスは自動でレンズが切り替わり画角が変わるので使わない。
  - 歪み補正はオン。画角はカメラの内部パラメータ、または歪み補正後の画角から求める。
  - iPhone 15 Proの超広角は35mm換算13mm（対角約120°）。
  - MoGe-2の学習時の画角の範囲と、超広角でのメトリックスケールの精度は未確認で、実機で測る必要がある。
