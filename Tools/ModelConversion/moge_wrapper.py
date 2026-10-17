"""MoGe-2 を Core ML 変換向けに書き直したラッパー。

- 入力サイズ固定（パッチ14の倍数）。トークン格子 = (H/14, W/14) なのでエンコーダ内のリサイズは恒等。
- DINOv2 の位置埋め込みは補間済みの定数として持つ（bicubic+antialiasを変換グラフに入れない）。
- 画像の正規化（ImageNet平均・標準偏差）をモデル内に入れる。入力は 0..255 の RGB（ImageType, scale=1/255 で 0..1 にする）。
- normal ヘッドは削除。
- 出力は「アフィン不変の点群（exp 再マップ後）」「マスク確率」「メトリックスケール」。
  focal/shift の復元（recover_focal_shift）はモデルに含めず、Swift 側で行う。
"""
from __future__ import annotations

import sys
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F

MOGE_SRC_ENV = "MOGE_SRC"


def add_moge_to_path(moge_src: str | Path | None = None) -> None:
    import os

    src = Path(moge_src or os.environ.get(MOGE_SRC_ENV, Path(__file__).parent / "third_party" / "MoGe"))
    if not (src / "moge").exists():
        raise FileNotFoundError(f"MoGe のソースが見つかりません: {src}（README の手順で clone してください）")
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))


def normalized_view_plane_uv(width: int, height: int) -> torch.Tensor:
    """moge.utils.geometry_torch.normalized_view_plane_uv と同じ。 (H, W, 2)"""
    aspect_ratio = width / height
    span_x = aspect_ratio / (1 + aspect_ratio**2) ** 0.5
    span_y = 1 / (1 + aspect_ratio**2) ** 0.5
    u = torch.linspace(-span_x * (width - 1) / width, span_x * (width - 1) / width, width)
    v = torch.linspace(-span_y * (height - 1) / height, span_y * (height - 1) / height, height)
    u, v = torch.meshgrid(u, v, indexing="xy")
    return torch.stack([u, v], dim=-1)


def _static_attention_forward(self, x: torch.Tensor, attn_bias=None) -> torch.Tensor:
    """DINOv2 Attention を静的形状で書き直す（トレース時に shape がテンソル化されるのを避ける）。"""
    n, c = int(x.shape[1]), int(x.shape[2])
    h = self.num_heads
    qkv = self.qkv(x).reshape(1, n, 3, h, c // h).permute(2, 0, 3, 1, 4)
    q, k, v = qkv[0], qkv[1], qkv[2]
    x = F.scaled_dot_product_attention(q, k, v)
    x = x.permute(0, 2, 1, 3).reshape(1, n, c)
    return self.proj(x)


class MoGe2CoreML(nn.Module):
    def __init__(self, moge, height: int, width: int, out_height: int | None = None, out_width: int | None = None):
        super().__init__()
        assert height % 14 == 0 and width % 14 == 0
        self.height, self.width = height, width
        self.rows, self.cols = height // 14, width // 14
        self.out_size = (out_height or height, out_width or width)

        for m in moge.modules():
            if m.__class__.__name__ == "Attention":
                m.forward = _static_attention_forward.__get__(m)
        self.encoder = moge.encoder
        self.neck = moge.neck
        self.points_head = moge.points_head
        self.mask_head = moge.mask_head
        self.scale_head = moge.scale_head
        assert moge.remap_output == "exp"

        # 位置埋め込みを事前に補間（元実装と同じ経路を eager で一度だけ実行）
        bb = self.encoder.backbone
        with torch.no_grad():
            dummy = torch.zeros(1, self.rows * self.cols + 1, bb.embed_dim)
            pos = bb.interpolate_pos_encoding(dummy, height, width)
        self.register_buffer("pos_embed_fixed", pos.clone())

        for level in range(5):
            uv = normalized_view_plane_uv(self.cols * 2**level, self.rows * 2**level)
            self.register_buffer(f"uv{level}", uv.permute(2, 0, 1).unsqueeze(0).contiguous())

    def encode(self, x: torch.Tensor):
        enc = self.encoder
        bb = enc.backbone
        x = (x - enc.image_mean) / enc.image_std
        x = bb.patch_embed(x)
        x = torch.cat((bb.cls_token.expand(1, -1, -1), x), dim=1)
        x = x + self.pos_embed_fixed
        if bb.register_tokens is not None:
            x = torch.cat((x[:, :1], bb.register_tokens.expand(x.shape[0], -1, -1), x[:, 1:]), dim=1)
        take = enc.intermediate_layers
        outs = []
        for i, blk in enumerate(bb.blocks):
            x = blk(x)
            if i in take:
                outs.append(x)
        feats = []
        cls_last = None
        for out in outs:
            out = bb.norm(out)
            cls_last = out[:, 0]
            feats.append(out[:, 1 + bb.num_register_tokens :])
        proj = None
        for p, f in zip(enc.output_projections, feats):
            y = p(f.permute(0, 2, 1).reshape(1, -1, self.rows, self.cols))
            proj = y if proj is None else proj + y
        return proj, cls_last

    def forward(self, image: torch.Tensor):
        feat, cls_token = self.encode(image)
        features = [torch.cat([feat, self.uv0], dim=1)] + [getattr(self, f"uv{i}") for i in range(1, 5)]
        features = self.neck(features)
        points = self.points_head(features)[-1]
        mask = self.mask_head(features)[-1]
        if points.shape[-2:] != self.out_size:
            points = F.interpolate(points, self.out_size, mode="bilinear", align_corners=False)
            mask = F.interpolate(mask, self.out_size, mode="bilinear", align_corners=False)
        # exp 再マップ: xy * exp(z), exp(z)
        xy, z = points[:, :2], points[:, 2:3]
        z = torch.exp(z)
        points = torch.cat([xy * z, z], dim=1)          # (1, 3, h, w)  channel = x, y, z
        mask = mask.sigmoid()                           # (1, 1, h, w)
        metric_scale = self.scale_head(cls_token).exp() # (1, 1)
        return points, mask, metric_scale


def load_moge(repo: str = "Ruicheng/moge-2-vits-normal"):
    add_moge_to_path()
    from moge.model.v2 import MoGeModel

    model = MoGeModel.from_pretrained(repo).eval()
    return model
