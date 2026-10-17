# route-dance スライド（Slidev）

route-dance の発表用スライド（約5分）。導入と技術まわりの説明。メインは iPhone アプリ。

## 使い方

```sh
cd docs/slides
pnpm install        # 初回のみ
pnpm dev            # ブラウザで開く（編集するとライブリロード）
```

- 本体: [slides.md](slides.md)
- 発表者ノートは各スライドの `<!-- ... -->` に書いてある（Presenter モードで表示）。

## 書き出し

```sh
pnpm build          # 静的サイト（dist/）
pnpm export         # PDF（要 playwright-chromium）
```

## 備考

- 開発進行中のため、構成・数値は変わる可能性がある。内容の出典は [../SPEC.md](../SPEC.md) / [../TECH_SELECTION.md](../TECH_SELECTION.md) / [../DEPTH_MODEL.md](../DEPTH_MODEL.md)。
