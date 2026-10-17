---
theme: seriph
background: '#0b0f1a'
title: route-dance
info: |
  ## route-dance
  カメラ映像から歩行者の動きを予測し、ぶつからない経路を重ねて表示するiOS ARアプリ
class: text-center
highlighter: shiki
drawings:
  persist: false
transition: slide-left
mdc: true
fonts:
  sans: 'Hiragino Sans, Noto Sans JP, sans-serif'
---

# route-dance

カメラ映像から周囲の歩行者の動きを予測し<br>**ぶつからずに歩ける経路**を映像に重ねて示す iOS ARアプリ

<div class="pt-8 opacity-70 text-sm">
すべての処理をデバイス上で完結 &nbsp;·&nbsp; iOS 27 / macOS 27
</div>

<!--
発表時間 約5分。まずは「何をするアプリか」を一言で。
自動運転車の実験映像のように、リアルタイム映像の上に「歩くべき一本の道」を重ねるイメージ、と伝える。
📸 スクリーンショット差し込み予定: 背景に実機アプリ画面（経路オーバーレイ）を薄く敷くと映える。
-->

---
layout: two-cols
layoutClass: gap-10
---

# 何を解くのか

人混みの中で、**他の歩行者とぶつからずに歩ける経路**を考えるのは地味に難しい。

- 相手がどう動くかを読む
- 自分の速度で間に合うか判断する
- どっちに避けるか決める

route-dance は、これをカメラ映像の上で**リアルタイムに可視化**する。

::right::

<div class="flex flex-col items-center justify-center h-full">

```mermaid {scale: 0.72}
flowchart TD
  U([あなた]) -->|歩く| G((ゴール<br/>端末の向きの最奥))
  P1(他歩行者) -.予測.-> P1b( )
  P2(他歩行者) -.予測.-> P2b( )
  U -->|推奨経路| route[緑→黄→赤<br/>の一本道]
```

<div class="text-xs opacity-60 mt-2">
緑=今の速度で通れる / 黄・赤=減速が必要
</div>

</div>

<!--
「歩きスマホ」前提のデモアプリである点、安全性は別途検討課題である点を一言添える。
-->

---

# 使い方のイメージ

<div class="grid grid-cols-3 gap-6 mt-6">

<div class="p-4 rounded-lg bg-white/5">
<div class="text-3xl">📱</div>
<div class="font-bold mt-2">映像に道を重ねる</div>
<div class="text-sm opacity-70 mt-1">地面の上に、今の歩行速度で約5秒先までたどれる一本の経路を描く</div>
</div>

<div class="p-4 rounded-lg bg-white/5">
<div class="text-3xl">🧭</div>
<div class="font-bold mt-2">コンパス型の矢印</div>
<div class="text-sm opacity-70 mt-1">進むべき向きを360°の矢印で示す</div>
</div>

<div class="p-4 rounded-lg bg-white/5">
<div class="text-3xl">🎥</div>
<div class="font-bold mt-2">動画でも同じ</div>
<div class="text-sm opacity-70 mt-1">撮り溜めた普通の動画に、ライブと同じUIを重ねて検証できる</div>
</div>

</div>

<div class="mt-8 text-sm opacity-70">
ゴール（v1）は「端末が向いている方向の、地面上で見える一番奥の点」。将来は地図で目的地を指定できるようにする。
</div>

---
layout: two-cols
layoutClass: gap-8
---

# はじめに：対象デバイス

メインは **iPhone アプリ** です 📱

<div class="mt-6 p-4 rounded-lg bg-white/5 text-sm">

**でも、なぜ macOS でも動くの？**

アプリを **2つ** 作ったからです。

</div>

<div class="mt-4 text-sm opacity-80">
UI もアルゴリズムも共有。違うのは「どこで動かすか」だけ。
</div>

::right::

<div class="mt-16">

### macOS 版 = デバッグ専用の双子
- UI・アルゴリズムは iPhone 版と**共有**
- 動画ファイルを流して動作を確認できる
- つまり、**動作はスマホ版とほぼ同じ**

<div class="mt-4 p-4 rounded-lg bg-white/5 text-sm opacity-80">
⚠️ 端末の性能が違うので、速度や発熱は少し変わる。<br>
「正しく動くか」は Mac で、「実機でどうか」は iPhone で確かめる。
</div>

</div>

<!--
開発を速く回すための工夫。Macなら動画を繰り返し流してアルゴリズムを詰められる。
コアは純SwiftなのでテストもMacでOK。
-->

---
layout: center
---

# どう動いているのか

<div class="text-base opacity-80 mb-4">カメラ1本の映像だけで、空間認識から経路計画までをデバイス上で完結させる</div>

```mermaid {scale: 0.6}
flowchart LR
  cam[カメラ / 動画] --> perc

  subgraph perc[知覚 Perception]
    depth[深度推定<br/>MoGe-2]
    det[人物検出<br/>Vision]
    flow[オプティカルフロー]
  end

  perc --> core

  subgraph core[コア 純Swift]
    ground[地面推定] --> odo[自己位置] --> loc[人物の位置] --> track[追跡] --> pred[軌道予測] --> plan[経路計画]
  end

  core --> render[描画<br/>Metal + SwiftUI]
```

<div class="text-xs opacity-60 mt-4">
コア（地面・自己位置・追跡・予測・計画）は純Swift。外部依存ゼロ、<code>swift test</code> でヘッドレス検証できる。
</div>

<!--
ここが全体像。以降のスライドはこのパイプラインの各ブロックを掘り下げる、と予告する。
-->

---

# 使っているアルゴリズム 一覧

<div class="text-sm">

| アルゴリズム | どんなもの | どこで使う |
| --- | --- | --- |
| **単眼メトリック深度**（MoGe-2） | 1枚の画像から深度・点群・画角を推定するNN | 空間を「画像だけ」で測る起点 |
| **RANSAC 平面当てはめ** | 外れ値に強い平面推定 | 点群から地面を見つける |
| **オプティカルフロー**（Lucas-Kanade） | 画素の動きを追う | 自分の移動（自己位置）の推定 |
| **SE(2) 剛体変換の推定** | 俯瞰での回転+並進を最小二乗 | 自己位置オドメトリ |
| **人物検出**（Vision） | 画像中の人の矩形を出すOS標準API | 他歩行者を見つける |
| **カルマンフィルタ** | 位置・速度の時系列推定 | 各歩行者の追跡 |
| **ByteTrack + ハンガリアン法** | 検出と既存トラックの対応付け | 複数人の追跡（MOT） |
| **等速度モデル(CVM) + 多峰サンプル** | 速度で外挿し、ばらつきを広げる | 他歩行者の軌道予測 |
| **CPA（最接近時刻）** | 相対速度から衝突の近さを測る | 何秒先まで予測するか |
| **サンプリング型経路探索** | 候補を多数生成し評価 | 推奨経路を選ぶ |
| **ST-graph 上の動的計画法** | 経路に沿った速度を最適化 | 減速区間（黄・赤）の決定 |

</div>

<!--
この表は「地図」。次からの技術スライドはこの中の主要なものを掘り下げる。
NNはMoGe-2と(将来の)予測モデルだけ。残りは古典的な幾何・最適化で、純Swiftで自前実装している点を強調。
-->

---
layout: two-cols
layoutClass: gap-8
---

# 技術① 空間を「画像だけ」で測る

LiDARやARKitは使わず、**単眼メトリック深度**を主軸にした。

**MoGe-2 ViT-S** (MIT, 35M) を Core ML 化

- 1枚の画像から **点群・深度・カメラ画角** を推定
- 画角も出すので、内部パラメータ不明の動画でも動く
- M4 Pro の ANE で **約37ms** / iPhone 15 Pro 推定 約55ms

::right::

<div class="mt-16 p-5 rounded-lg bg-white/5 text-sm">

**なぜ画像だけ？**

ライブ映像と、撮り溜めた普通の動画が<br>**まったく同じ処理経路**を通る。

→ 動画での評価結果が、そのまま<br>ライブの性能になる。

<div class="opacity-60 mt-3 text-xs">
深度の絶対スケール誤差は、地面から得たカメラ高さで補正して安定させる。
</div>

</div>

<!--
深度モデルの選定はライセンス(MIT)・サイズ・画角推定の有無で決めた、と補足。
-->

---

# 技術② 地面と自分の動きを推定する

<div class="grid grid-cols-2 gap-8 mt-4">

<div>

### 地面平面
深度の点群から **RANSAC** で地面を当てはめる

- カメラの高さと傾きが得られる
- ライブでは CoreMotion の重力で補正
- カメラ高さを平滑化して深度スケールを安定化

</div>

<div>

### 自己位置（画像オドメトリ）
地面上の点を **オプティカルフロー**で追い、俯瞰座標で SE(2) を推定

- 自前のピラミッド型 Lucas-Kanade
- 他歩行者の枠内は除外（自分の動きと誤認しない）
- ライブではジャイロと融合

</div>

</div>

<div class="mt-6 text-sm opacity-70">
歩行速度はこの並進を1〜1.5秒の窓で平滑化して求める。
</div>

---
layout: two-cols
layoutClass: gap-8
---

# 技術③ 人を見つけて追う

### 検出
**Vision** の人物矩形検出（OS標準・iOS/macOS共通）

### 地面上の位置
- 足元レイと地面の交点
- 深度の中央値
- 身長の事前分布（足元が切れたとき）

→ 各手法を**分散で重み付け**して統合

::right::

<div class="mt-8">

### 追跡（MOT）
**ByteTrack方式を自前Swift実装**

- 地面座標の等速カルマンフィルタ
- 毎フレーム自己位置の変化で全トラックを補正
- 2段階マッチング + ハンガリアン法

<div class="mt-6 p-4 rounded-lg bg-white/5 text-sm opacity-80">
追跡の状態は<strong>地面座標</strong>で持つ。<br>
画面上ではなく実空間で「どこに誰がいるか」を追う。
</div>

</div>

---

# 何を「障害物」として扱うか

<div class="grid grid-cols-2 gap-8 mt-4">

<div>

### 障害物 = 他の歩行者
いま避ける対象は**動く人**に絞っている。

- 各歩行者を**地面座標の点＋半径**で表す<br>（体の半径 + パーソナルスペース ≒ 0.6m）
- 止まっている物・壁などは v1 では扱わない

<div class="mt-4 text-xs opacity-60">
将来は地面として通れない領域（段差・車道など）への拡張余地あり。
</div>

</div>

<div>

### 処理の工夫
- **未来の位置**を障害物にする<br>今いる場所でなく、予測軌道で避ける
- **確率として扱う**<br>1点でなくサンプル軌道の集合 → 衝突「確率」で評価
- **相手は避けてくれない前提**（安全側に倒す）
- **近い人ほど重視**（CPA で予測を長くとる）
- **自分の動きと分離**<br>人物の枠内はオドメトリから除外

</div>

</div>

<div class="mt-6 p-3 rounded bg-white/5 text-sm opacity-80">
ポイント: 障害物は「今その場にいる人」ではなく「<strong>これから数秒間に人がいそうな時空間の領域</strong>」として扱う。
</div>

<!--
時刻付きの占有として扱うのが肝。ユーザーがそのセルに到達する時刻に、そこに誰かがいる確率で危険度を測る。
-->

---

# 画面の見かた（デバッグ詳細表示）

<div class="text-sm opacity-70 mb-3">デバッグモード（デフォルトON）では、各処理が正しく動いているかを一目で確認できる。映像は白っぽく加工してオーバーレイを見やすくする。</div>

<div class="grid grid-cols-2 gap-x-8 gap-y-2 text-sm mt-2">

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-5 border-2 border-cyan-400 rounded-sm shrink-0"></span>
<div><b>検出枠</b> … Vision が見つけた人物。枠の上に<b>トラックID</b>と<b>距離</b></div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-1.5 bg-orange-400 rounded shrink-0"></span>
<div><b>予測経路</b> … 各歩行者が今後とりそうな<b>サンプル軌道</b>の線（K本）</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-1.5 bg-gradient-to-r from-green-500 via-yellow-400 to-red-500 rounded shrink-0"></span>
<div><b>推奨経路</b> … 緑=今の速度で通れる / 黄・赤=減速が必要</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-1.5 bg-white/40 rounded shrink-0"></span>
<div><b>候補経路</b> … 探索した経路群を薄く表示（P_safe の色）</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-5 rounded-sm shrink-0" style="background:linear-gradient(135deg,rgba(255,0,0,.6),rgba(0,255,0,.3))"></span>
<div><b>ヒートマップ</b> … 地面の各点に「そこへ行くとぶつかる確率」を色で</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 inline-block w-5 h-5 border border-white/50 shrink-0" style="background:repeating-linear-gradient(45deg,transparent,transparent 3px,rgba(255,255,255,.3) 3px,rgba(255,255,255,.3) 4px)"></span>
<div><b>地面平面</b> … RANSAC で推定した地面グリッド</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 text-lg leading-none shrink-0">🧭</span>
<div><b>コンパス矢印</b> … 進むべき向き（360°回転）</div>
</div>

<div class="flex items-start gap-3">
<span class="mt-1 text-lg leading-none shrink-0">⊕</span>
<div><b>ゴール</b> … 端末の向きの、地面上で見える最も奥の点</div>
</div>

</div>

<div class="mt-4 p-2 rounded bg-white/5 text-xs opacity-70">
<b>上部の HUD</b>: 歩行速度 / FPS / 検出数 / 追跡数 / 各処理の時間 / 自己位置の状態 / カメラ高さ / 入力ソース
</div>

<!--
📸 スクリーンショット差し込み予定: 実際のデバッグ画面を右側か背景に置き、各要素から引き出し線を引けると理想。
まずは凡例だけでも、画面を見せたときに「どれが何か」が伝わる。
-->

---

# （デモ）実際の表示

<div class="mt-8 p-8 rounded-lg bg-white/5 border-2 border-dashed border-white/20 text-center">

📸 **スクリーンショット差し込み予定**

ここに iPhone 実機（またはMacで動画再生）の画面を貼る：<br>
映像の上に推奨経路（緑→黄→赤）・コンパス矢印・HUD が重なった様子

<div class="text-xs opacity-50 mt-3">
デバッグモードON（予測経路・衝突確率ヒートマップ・検出枠）版と、通常版の2枚あると良い
</div>

</div>

<!--
デモ動画を流せるなら、ここで実機またはMacの画面を見せる。静止画が難しければ動画キャプチャでも可。
-->

---
layout: two-cols
layoutClass: gap-8
---

# 技術④ 動きを予測する

**等速度モデル(CVM) + 多峰サンプル**（Phase 1）

- 追跡で得た速度で外挿
- 不確かさは時間とともに広げる
- 向き・速さを摂動した **K本のサンプル軌道**
- 出力は「重み付きサンプル軌道の集合」に統一
  → 後段が予測器に依存しない

<div class="text-xs opacity-60 mt-3">
学習モデル（EqMotion等）はPhase 2で同じ基盤で比較予定。単純な場面ではCVMが深層モデルと同等以上という研究もある。
</div>

::right::

<div class="mt-12 p-5 rounded-lg bg-white/5 text-sm">

### 何秒先まで予測する？
**最接近時刻(CPA)ベースの可変ホライズン**

$$t_{cpa} = \max\left(0,\ -\frac{p \cdot v}{|v|^2}\right)$$

$$N = \mathrm{clamp}(t_{cpa} + \tau,\ N_{min},\ N_{max})$$

<div class="opacity-70 mt-3 text-xs">
近づいてくる人は短く、関係ない人は長く。<br>
「距離÷速度」だと同方向の人に短すぎ・停止時に発散する問題を回避。
</div>

</div>

---

# 技術⑤ 経路を決めて、色で示す

<div class="grid grid-cols-2 gap-8 mt-4">

<div>

### 経路の探索
歩行速度は固定し、**向き（曲率）の列だけ**を探索

- 約5秒先までの候補を数百本生成
- 各候補 × 各歩行者のサンプル軌道で<br>**衝突しない確率** $P_{safe}$ を評価
- ゴールへの近さ・前回との差も加味

</div>

<div>

### 減速区間の表示
避けきれない所は **ST-graph 上のDP** で速度プロファイルを求める

<div class="mt-3 flex gap-2">
<span class="px-3 py-1 rounded bg-green-500/80 text-xs">緑 = 今の速度で通れる</span>
</div>
<div class="mt-2 flex gap-2">
<span class="px-3 py-1 rounded bg-yellow-400/80 text-black text-xs">黄 = 少し減速</span>
<span class="px-3 py-1 rounded bg-red-500/80 text-xs">赤 = 大きく減速</span>
</div>

<div class="text-xs opacity-60 mt-3">
自動運転のパス-速度分解と同じ考え方。
</div>

</div>

</div>

---
layout: center
class: text-center
---

# 設計の背骨

<div class="grid grid-cols-3 gap-6 mt-8">

<div class="p-5 rounded-lg bg-white/5">
<div class="text-2xl">🔒</div>
<div class="font-bold mt-2">オンデバイス完結</div>
<div class="text-sm opacity-70 mt-2">推論も計算もすべて端末内。ネットワーク通信なし</div>
</div>

<div class="p-5 rounded-lg bg-white/5">
<div class="text-2xl">🔁</div>
<div class="font-bold mt-2">ライブ = 動画</div>
<div class="text-sm opacity-70 mt-2">画像だけで空間認識するから、ライブと動画が同一パイプライン</div>
</div>

<div class="p-5 rounded-lg bg-white/5">
<div class="text-2xl">🧩</div>
<div class="font-bold mt-2">依存ゼロ</div>
<div class="text-sm opacity-70 mt-2">Apple純正 + 自前実装のみ。コアは純Swiftで差し替え可能</div>
</div>

</div>

<div class="mt-8 text-sm opacity-70">
Mac でも同じUI・同じアルゴリズムで動画を流して検証できる。
</div>

---
layout: two-cols
layoutClass: gap-8
---

# 現状と今後

### できていること
- コアアルゴリズム（`swift test` が通る）
- MoGe-2 の Core ML 化（ANEで約37ms）
- HUD・ドロワー・コンパス・オーバーレイのUI
- 検出→追跡→予測→計画→描画 の接続
- iOSライブカメラ / 写真動画（実装済み）

::right::

<div class="mt-16">

### これから
- 実写の歩行動画でパラメータ調整
- **iPhone実機での検証**（速度・精度・発熱）
- 予測・追跡の評価（ADE/FDE など）
- 学習型予測器との比較（Phase 2）
- 地図による目的地指定

<div class="text-xs opacity-50 mt-4">
※ 開発進行中。構成・数値は変わる可能性があります。
</div>

</div>

---
layout: center
class: text-center
---

# まとめ

<div class="text-lg opacity-90 mt-4 leading-relaxed">

カメラ1本の映像から、<br>
**周囲の歩行者を予測し、ぶつからない道を重ねて示す** iOSアプリ。

</div>

<div class="mt-8 grid grid-cols-2 gap-4 max-w-2xl mx-auto text-sm">
<div class="p-3 rounded bg-white/5">画像だけで空間を測る（単眼深度）</div>
<div class="p-3 rounded bg-white/5">CPAで予測、確率で計画</div>
<div class="p-3 rounded bg-white/5">すべてオンデバイス</div>
<div class="p-3 rounded bg-white/5">ライブと動画が同じ処理</div>
</div>

<div class="mt-10 opacity-60 text-sm">
ありがとうございました
</div>
