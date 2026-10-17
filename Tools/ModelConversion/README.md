# モデル変換（MoGe-2 → Core ML）

単眼メトリック深度モデル MoGe-2 ViT-S を Core ML（mlprogram、FP16）に変換し、検証する手順。
採用理由・入出力仕様・計測結果は [docs/DEPTH_MODEL.md](../../docs/DEPTH_MODEL.md) を参照。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `moge_wrapper.py` | MoGe-2 を変換向けに書き直したラッパー（固定サイズ、正規化込み、normal削除、後処理なし） |
| `convert_moge.py` | 変換スクリプト |
| `compare_moge.py` | PyTorch版とCore ML版の出力比較（深度の相対誤差、FoV、スケール） |
| `bench_coreml.py` | レイテンシ計測と `MLComputePlan` によるANE割り当て確認 |
| `gen_postprocess_fixtures.py` | `MoGePostprocess.swift` のテストフィクスチャ生成 |
| `requirements.txt` | 検証済みのバージョン（`uv pip freeze` の結果） |

## 1. 環境構築

```sh
brew install uv                       # 未導入なら
cd Tools/ModelConversion
uv venv --python 3.11 .venv
source .venv/bin/activate

# torch は 2.7.0 に固定する（coremltools 9.0 が検証済みの最新。これより新しいと変換が不安定になる）
uv pip install "torch==2.7.0" "torchvision==0.22.0" coremltools numpy pillow huggingface_hub safetensors \
  click scipy opencv-python-headless matplotlib trimesh requests tqdm \
  "utils3d_moge @ git+https://github.com/EasternJournalist/utils3d-moge.git@62f09d58509485564e24d5d9f6aac9ee9ebc0c37"
# もしくは: uv pip install -r requirements.txt
```

MoGe のソースを `third_party/MoGe` に置く（`.gitignore` 済み。コミット `74fbce0` で検証）。
`MOGE_SRC` 環境変数で別の場所も指せる。

```sh
git clone https://github.com/microsoft/MoGe.git third_party/MoGe
git -C third_party/MoGe checkout 74fbce0
```

重みは初回実行時に Hugging Face（`Ruicheng/moge-2-vits-normal`、MIT）から自動で取得される。

## 2. 変換

```sh
# 縦持ち 3:4（既定。378x504 = 27x36 トークン = 972）
python convert_moge.py --height 504 --width 378 --out ../../Models/MoGe2S.mlpackage
# 横持ち 4:3
python convert_moge.py --height 378 --width 504 --out ../../Models/MoGe2S_landscape.mlpackage
# 縦持ち 9:16 / 横持ち 16:9（iPhoneの標準動画向け。1296 トークン）
python convert_moge.py --height 672 --width 378 --out ../../Models/MoGe2S_9x16.mlpackage
python convert_moge.py --height 378 --width 672 --out ../../Models/MoGe2S_16x9.mlpackage
# 速度優先（336x448 = 24x32 トークン = 768）
python convert_moge.py --height 448 --width 336 --out ../../Models/MoGe2S_fast.mlpackage
```

入力サイズは14の倍数にする。`.mlpackage` は `Models/`（`.gitignore` 済み）に出力される。

## 3. 検証

```sh
# サンプル画像（街中の歩行者画像）を用意する。out/ は .gitignore 済み。
mkdir -p out/samples
cp third_party/MoGe/example_images/03_Traffic.jpg out/samples/moge_traffic.jpg
# Wikimedia Commons の歩行者写真（CC系ライセンス）を使った。取得方法は docs/DEPTH_MODEL.md の付録を参照。

# PyTorch(FP32) と Core ML(FP16) の比較。両者を MoGe 公式の recover_focal_shift で後処理して比べる。
python compare_moge.py --model ../../Models/MoGe2S.mlpackage --images out/samples/*.jpg

# レイテンシ計測（computeUnits 別）と、--plan で MLComputePlan によるデバイス割り当て
python bench_coreml.py ../../Models/MoGe2S.mlpackage --plan
```

## 4. Swift後処理のフィクスチャ

```sh
python gen_postprocess_fixtures.py \
  --model ../../Models/MoGe2S.mlpackage \
  --images out/samples/london_portrait.jpg out/samples/charles_bridge.jpg out/samples/moge_traffic.jpg \
  --out ../../Packages/RouteDanceCore/Tests/RouteDanceCoreTests/Fixtures/MoGe

cd ../../Packages/RouteDanceCore && swift test --filter MoGePostprocessTests
```

フィクスチャは 72x96 に間引いた生出力（float32、約108KB × 3枚）と、公式実装の期待値（`cases.json`）。

## 5. 変換上の注意（はまりどころ）

- **torch のバージョン**: coremltools 9.0 は torch 2.7.0 まで検証済み。新しい torch だと警告が出て不安定になる。
- **DINOv2 の Attention**: トレース時に `x.shape` がテンソル化されて `int()` で失敗するため、`moge_wrapper.py` で
  静的形状版の forward に差し替えている（数式は同一。PyTorch元実装と出力がビット一致することを確認済み）。
- **位置埋め込み**: 入力サイズごとに bicubic 補間した結果を定数として持たせ、グラフに補間を入れない。
- **UV座標**: 各解像度の視野面UV（`normalized_view_plane_uv`）も定数バッファ化している。
- **`recover_focal_shift` はモデルに含めない**: scipy の最小二乗なのでCore MLに入らない。Swiftで実装した。
- バッチサイズは1固定。
