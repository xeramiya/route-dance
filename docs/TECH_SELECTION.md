# 技術選定（レビュー用）

> ステータス: **レビュー待ち**
> 調査日: 2026-10-17
> 関連: [SPEC.md](SPEC.md)

## 0. 結論（TL;DR）

| レイヤ | 採用（第1候補） | 代替 / 将来 |
| --- | --- | --- |
| 言語・UI | Swift 6 / SwiftUI（iOS + macOSマルチプラットフォーム） | — |
| 自己位置・姿勢 | **ARKit** `ARWorldTrackingConfiguration`（6DoF、重力整列ワールド座標） | 動画入力時は記録済みの姿勢、または単眼推定 |
| 深度 | **LiDAR `sceneDepth`**（〜5m）＋**地面平面への足元レイキャスト**（遠距離） | `personSegmentationWithDepth`（非LiDAR機）、Depth Anything V2 Small（Apache-2.0） |
| 人物検出 | **Vision `DetectHumanRectanglesRequest`**（OS標準、iOS/macOS共通、ライセンス問題なし） | YOLOX（Apache-2.0）/ MIT版YOLO（MultimediaTechLab/YOLO）をCore ML化 |
| 追跡 | **ByteTrack方式を自前Swift実装**（地面座標のカルマンフィルタ＋2段階マッチング） | OC-SORTの観測中心の再更新を追加 |
| 軌道予測 | **等速度モデル(CVM)＋不確かさ拡大＋多峰サンプリング**（物理ベース、Phase 1） | Core ML化した学習モデル（EqMotion / Trajectron++ / MoFlow、すべてMIT）をPhase 2で比較 |
| 予測ホライズンN | **最接近時刻(t_CPA)ベースの可変N**（仕様の d/v を一般化） | 仕様どおりの d/v（設定で切替可能にする） |
| 経路計画 | **一定速度でのサンプリング型経路探索＋サンプルベースの衝突確率**（DWA/lattice系） | MPPIでの局所改善、PGIF型の異方性リスク場 |
| 減速区間 | **パス-速度分解（ST-graph上のDP）** で速度プロファイルを求め、色分けする | — |
| 描画 | Metal（`MTKView`）でカメラ映像＋デバッグ加工、SwiftUI `Canvas`でオーバーレイ | 重くなったらオーバーレイもMetal化 |
| 動画評価 | **アプリ内の記録モード**（映像＋ARKit姿勢・内部パラメータ・深度を保存）→ iPhone/Macで同一パイプラインで再生 | 写真ライブラリの任意動画は「単眼モード」（精度は落ちる） |
| Mac | **同一コード・同一UIで動かせる**（ARKitだけ`#if os(iOS)`で分離） | `swift test`によるヘッドレス評価（ADE/FDEなど） |
| プロジェクト管理 | XcodeGen（`project.yml`をGit管理）＋ローカルSwift Package | Xcodeのフォルダ同期のみ |

**Macでのテストは「できる」と判断しました。** 理由は、ARKitを使うのは「センサ入力」の部分だけで、検出（Vision）、Core ML、追跡・予測・計画（純Swift）、描画（Metal/SwiftUI）はすべてmacOSでも動くからです。最初から入力層を抽象化しておけば、追加コストは小さく済みます（§6）。

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

## 2. 空間認識（他歩行者の3D位置）

### 2.1 ARKit ✅

| 機能 | 対応 | 本アプリでの使い道 |
| --- | --- | --- |
| `ARWorldTrackingConfiguration` | iOS 11+（**macOS・Mac Catalyst非対応**） | カメラの6DoF姿勢。重力に揃ったワールド座標が得られ、ユーザー速度もここから求める |
| `ARFrame.sceneDepth` / `smoothedSceneDepth` | iOS 14+、LiDAR機のみ | 近距離（目安〜5m）の人物までの距離 |
| `personSegmentationWithDepth`（`segmentationBuffer`、`estimatedDepthData`） | iOS 13+、A12以降 | 非LiDAR機での人物マスクと推定深度 |
| `sceneReconstruction` | iOS 13.4+、LiDAR | 静的障害物（壁・柱）。Phase 2以降 |
| `ARBodyTrackingConfiguration` | iOS 13+ | **不採用**: 追跡できるのは1人だけで、複数の他歩行者に使えない |

### 2.2 人物検出

| 候補 | ライセンス | iOS / macOS | 評価 |
| --- | --- | --- | --- |
| **Vision `DetectHumanRectanglesRequest`**（Swift API、iOS 18+） / `VNDetectHumanRectanglesRequest`（iOS 13+） | OS標準 | ✅ 両方 | **第1候補**。追加モデル不要で、Macでも同じ結果。遠くの小さな人物の検出率は ⚠️ 実機で要確認 |
| Ultralytics YOLO11 / YOLOv8 | ✅ **AGPL-3.0**（HF上のYOLO11もAGPL） | Core ML出力あり | **不採用**。アプリ全体をAGPLで公開するか、Enterpriseライセンスの購入が必要 |
| YOLOv10 / YOLOv12 | ✅ AGPL-3.0 | — | 同上で不採用 |
| YOLOX | ✅ Apache-2.0 | 純CNNなのでCore ML化は容易 ⚠️ | **Plan B** |
| MultimediaTechLab/YOLO（YOLOv9系をMITで再実装） | ✅ MIT | ⚠️ | Plan B |
| RF-DETR / D-FINE / RT-DETR | ✅ Apache-2.0 | DETR系はCore ML変換で詰まる可能性あり ⚠️ | 精度が足りないときの候補 |
| apple/coreml-YOLOv3 | ✅ MIT | 変換済み | 古いので比較用 |

検出器は`PersonDetector`プロトコルの裏に隠し、差し替えられるようにする。

### 2.3 3D位置推定（深度の統合）

人物の位置は**足元の地面上の点 (x, z)** として表す。

1. **近距離（LiDARの範囲内）**: 検出枠内の`sceneDepth`（人物マスクと重なる画素に限定）の中央値を使う。
2. **遠距離**: 検出枠の下端中央（足元）から光線を飛ばし、地面平面と交差させる。地面の高さはARKitの水平平面検出か、カメラ高さの推定値から得る。距離に上限がなく、**動画入力でも同じ方法が使える**のが利点。
3. 両方が使える距離帯では、分散で重み付けして統合する。

単眼深度（動画入力・非LiDAR機向けの補助）:

| 候補 | ライセンス | 備考 |
| --- | --- | --- |
| apple/coreml-depth-anything-v2-small | ✅ Apache-2.0 | Apple公式のCore ML変換版。F16で約50MB。iPhone 15 Pro Maxで約34ms（ANE）。出力は**相対深度** |
| Depth Anything V2 Base/Large/Giant | ✅ CC-BY-NC-4.0 | **非商用のため不採用** |
| Metric-Video-Depth-Anything-Small | ✅ Apache-2.0 | メートル単位で時間方向に安定。ただしCore ML変換は自前 ⚠️ |
| Apple Depth Pro | ✅ apple-amlrライセンス（研究用途向け） | **アプリ組み込みは不採用**。Macでの評価用の参照としてのみ検討 |

### 2.4 追跡（MOT）

- Swift製の成熟したByteTrack/OC-SORT実装はGitHubで見つからなかった（✅ 検索で確認）。元実装はByteTrack・OC-SORT・BoT-SORTとも ✅ MIT。
- **自前で実装する**（数百行の規模）。
  - 状態は**ワールドの地面座標**上の位置・速度（定速カルマンフィルタ）。画像座標ではなくワールド座標で追うので、ユーザーの移動やカメラの揺れの影響を受けにくい。
  - マッチングはByteTrack方式: 高スコア検出→低スコア検出の2段階。コストは画像IoUとワールド距離の組み合わせ。
  - OC-SORTの、見失いから戻ったときの再更新（ORU）を後から追加する。

### 2.5 ユーザーの歩行速度

- ARKitのカメラ位置を水平面に投影して微分し、平滑化する（歩行の上下動や手ブレを除くため、1〜2秒の窓で処理）。
- 補助として`CMPedometer.currentPace`（✅ iOS/macOSのAPI）を使う。
- 進行方向は**移動方向**（速度ベクトル）で決め、カメラの向きとは区別する。

---

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
- 実装: 内部の衝突評価は全員について計画ホライズン T_plan まで行う（CVMなら軽い）。N_iは**表示範囲と影響範囲**に使う。設定ドロワーで「d/v方式」と「CPA方式」を切り替えて比較できるようにする。

---

## 4. 経路計画

### 4.1 要件の整理

- ユーザーの**現在の歩行速度 v で辿れる経路**を出す → 速度は固定し、**向き（曲率）の列だけを探索**する。
- それでも避けられない場合だけ減速する → 減速区間を黄〜赤で示す。
- 目的地の入力はない → 「行きたい方向」は**ユーザーの現在の進行方向**（平滑化したもの）とする（§9 Q4）。

### 4.2 アルゴリズム（Phase 1）

1. **候補の生成**: 速度vで、T_plan（例: 6秒、または8m/vの短い方）までの候補経路を生成する。
   - 曲率が一定の円弧、2段の円弧（一度曲がってから戻る）、最大旋回レートの制約付き。
   - 数は数百本程度。DWA / state latticeの考え方（📚）。
2. **衝突確率**: 各候補について、各他歩行者のサンプル軌道kとの距離が R（体の半径＋パーソナルスペース、例: 0.6m）を下回るかを時刻ごとに評価する。
   ```
   p_i = Σ_k w_k · σ((R − min_t |x(t) − s_ik(t)|) / ε)    （微分可能なソフト版）
   P_safe = Π_i (1 − p_i)                                  （他歩行者は互いに独立と仮定）
   ```
3. **コスト**: J = w_risk·(1−P_safe) + w_goal·|行きたい方向からのずれ| + w_smooth·|前回の計画との差|
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
- **地面のオーバーレイ**（経路、ヒートマップ、予測経路）: ワールド座標の点をカメラの内部パラメータと姿勢で画面に投影し、SwiftUIの`Canvas`で描く。重くなったらMetal化する。
  - **RealityKitの`ARView`は使わない**。`ARSession`を前提にしているので、動画再生とMacで同じUIにできないため。
- **HUD（上部に常時表示）**: ユーザー速度、FPS、検出数、追跡数、各段の処理時間、ARKitの追跡状態、深度の取得元（LiDARか地面平面か）。
- **ドロワー**: 左下のハンバーガーメニューから下からせり上がるシート。中身は「デバッグモード（デフォルトON）」「ホライズン方式」「入力ソース（ライブ / 記録 / 動画）」「記録の開始・停止」など。

---

## 6. 動画入力・評価・Mac対応

### 6.1 アーキテクチャ（入力層を抽象化する）

```
FrameSource (protocol)
 ├─ ARKitFrameSource        … iOSのライブ入力（ARSession）           #if os(iOS)
 ├─ RecordedSessionSource   … アプリで記録したセッション（iOS / macOS）
 └─ PlainVideoSource        … 写真ライブラリなどの任意動画（iOS / macOS）
        ↓  Frame { 画像, 時刻, カメラ内部パラメータ, 姿勢?, 深度?, 地面? }
Perception（Vision / Core ML） → Tracker → Predictor → Planner → Renderer / HUD
                      ↑ ここから下はiOSとmacOSで共通コード
```

### 6.2 写真ライブラリの動画に同じUIを重ねられるか → **できる。ただし2段階に分ける**

1. **記録セッション（推奨・高精度）**: アプリに記録モードを付ける。HEVCの映像に加えて、フレームごとの姿勢、内部パラメータ、LiDAR深度（間引き・圧縮）、時刻を保存し、ライブと**まったく同じ条件で**再生する。再現性があるので、アルゴリズムの比較やリグレッションテストに使える。
2. **任意の動画（簡易・精度低め）**: ARKitのデータがないので、次の方法で推定する。
   - 内部パラメータ: 動画のメタデータ（焦点距離）から求める。なければ画角を仮定する。
   - 地面: カメラ高さ（例: 1.4m）と俯角を仮定するか、設定で調整する。
   - ユーザーの移動: Visionのホモグラフィ推定やオプティカルフロー（`TrackOpticalFlowRequest`、✅ iOS 18+/macOS 15+）を、画像下部の地面領域に適用して推定する。
   - 深度: 地面平面へのレイキャスト。必要に応じてDepth Anything V2 Smallで補う。

   精度は1.より明らかに落ちるので、HUDに「単眼モード」と表示する。

### 6.3 Macで動かせるか → **できる**

- ✅ Vision（人物検出・オプティカルフロー）、Core ML、Metal、SwiftUI、CoreMotionはmacOSでも使える。
- ✅ ARKitはiOS/iPadOSのみで、**Mac Catalystにも存在しない**ので、ネイティブのmacOSターゲットを用意し、ARKit部分は`#if os(iOS)`で分ける。
- Macでは記録セッションと任意動画を再生でき、UIは同じ。ファイルのドラッグ＆ドロップとコマ送りも付けられる。
- さらに`RouteDanceCore`パッケージに対して`swift test`でヘッドレス評価を回せる。

### 6.4 評価指標

| 対象 | 指標 | 正解データ |
| --- | --- | --- |
| 予測 | ADE/FDE（ホライズン別）、minADE_K、NLL | 記録セッションでは**全区間を見た後処理の追跡結果**（前後方向の平滑化）を疑似正解にする。ETH/UCYでは公式の正解 |
| 追跡 | IDスイッチ数、トラックの寿命 | 目視でのラベル付け（少量） |
| 計画 | 他歩行者との最小距離、予測上の衝突率、推奨方向の揺れ（°/s）、減速率 | 記録セッション |
| 性能 | 各段の処理時間、FPS、端末の温度状態 | 実機 |

- ETH/UCYを読み込むツールを用意し、予測器の実装が論文の値（例: CVMのADE）を再現するかをCIなしでもローカルで確認する。
- JRDB（ego視点のロボットデータセット）は利用条件が ⚠️ 未確認。

---

## 7. 開発環境・プロジェクト構成

- Xcode 26.6 / Swift 6.3（strict concurrency）/ Swift Testing。
- **Deployment target: iOS 18.0 / macOS 15.0**。新しいVision Swift API（`DetectHumanRectanglesRequest`、`TrackOpticalFlowRequest`）を使うため（§9 Q1）。
- 実機: iPhone 15 Pro（LiDARあり）を想定。非LiDAR機では`personSegmentationWithDepth`と地面平面方式で動かす。
- **XcodeGen**（`project.yml`）でプロジェクトを生成し、`.xcodeproj`はGit管理しない。プロジェクトファイルの衝突がなくなる（§9 Q3）。
- 構成案:

```
route-dance/
├─ project.yml                 # XcodeGen
├─ App/                        # SwiftUIアプリ（iOS + macOS）
│  ├─ Shared/                  # UI（HUD, Drawer, Overlay, Compass）
│  ├─ iOS/                     # ARKitFrameSource, Recorder
│  └─ macOS/
├─ Packages/RouteDanceCore/    # 純Swift: Geometry, Tracking, Prediction, Planning, Eval
│  └─ Tests/
├─ Tools/                      # 評価CLI, モデル変換スクリプト(Python)
└─ docs/                       # SPEC.md, TECH_SELECTION.md
```

- 外部依存は**なし**から始める（すべてApple純正のフレームワークと自前実装）。Core MLモデルは`.gitignore`に入れ、取得スクリプトかGit LFSで管理する。

---

## 8. マイルストーン

| # | 内容 | 完了条件 |
| --- | --- | --- |
| M0 | Git、ドキュメント、XcodeGen、空のアプリ（iOS/macOS）、Coreパッケージ | iOSとmacOSでビルドが通る |
| M1 | ARSession、カメラ描画（デバッグ時の白っぽい加工）、HUD（速度・状態）、ドロワー | 実機で速度が表示される |
| M2 | 人物検出→3D位置→追跡、デバッグ表示（検出枠、ID、距離） | 歩行者に安定したIDが付く |
| M3 | CVM予測、可変ホライズン、予測経路の表示 | 予測経路が表示される |
| M4 | 経路計画、減速の色分け、コンパス矢印、衝突確率のヒートマップ | 推奨経路と矢印が表示される |
| M5 | 記録と再生（iOS/macOS）、評価指標 | Macで記録を再生でき、指標が出る |
| M6 | 任意動画の単眼モード | 写真ライブラリの動画で表示できる |
| M7 | 学習型予測器のCore ML化と比較 | 評価表 |

---

## 9. レビューで決めてほしいこと

1. **Deployment target**: iOS 18 / macOS 15で良いか（iOS 26に上げれば最新APIを自由に使えるが、対象端末が減る）。
2. **軌道予測の進め方**: 「Phase 1は物理ベース(CVM)、Phase 2で学習モデル」で良いか。最初から学習モデルを入れたい場合は、M3の期間が延びる。
3. **XcodeGenの導入**（`brew install xcodegen`）で良いか。
4. **「行きたい方向」の定義**: 目的地の入力がないので、現在の進行方向とする案で良いか（代案: カメラの向き、画面タップで方向を指定）。
5. **予測ホライズンN**: CPAベースをデフォルトにし、d/v方式は切替で残す、で良いか。
6. **任意動画の扱い**: 本命は記録セッション、任意動画は精度の落ちる単眼モード、という2段構えで良いか。

## 10. リスク

- **歩きスマホの安全性**: 画面を見ながら歩く使い方そのものにリスクがある。注意表示などの扱いは別途検討する。
- Visionの人物検出の遠距離での性能 ⚠️ → 足りなければYOLOX等に差し替える。
- LiDARの有効距離（〜5m）を超える人物は地面平面方式に頼るので、坂や段差で誤差が出る。
- ego視点の観測ノイズ（オクルージョン、画角外へのフレームアウト）が予測精度を大きく下げる。追跡の安定化が最重要。
- 熱と電池: ARKit＋検出＋深度の常時実行。検出は10〜15Hzに間引き、描画は60fpsで補間する。
- 学習モデルの重みとデータセットのライセンス（商用で使えるかどうか）。

## 11. 出典

一次情報（今回確認したもの）:

- 軌道予測: [MoFlow](https://moflow-imle.github.io/) / [arXiv 2503.09950](https://arxiv.org/abs/2503.09950)、[EqMotion](https://github.com/MediaBrain-SJTU/EqMotion)、[LED](https://github.com/MediaBrain-SJTU/LED) / [arXiv 2303.10895](https://arxiv.org/abs/2303.10895)、[SingularTrajectory](https://github.com/InhwanBae/SingularTrajectory)、[EigenTrajectory](https://github.com/InhwanBae/EigenTrajectory)、[Trajectron++](https://github.com/StanfordASL/Trajectron-plus-plus)、[AgentFormer](https://github.com/Khrylx/AgentFormer)、[T2FPV](https://github.com/cmubig/T2FPV) / [arXiv 2209.11294](https://arxiv.org/abs/2209.11294)
- 可変ホライズン・計画: [arXiv 2603.00507](https://arxiv.org/abs/2603.00507)、[arXiv 2607.09192](https://arxiv.org/abs/2607.09192)、[arXiv 2608.08323 (PGIF)](https://arxiv.org/abs/2608.08323)
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
