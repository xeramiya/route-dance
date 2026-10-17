#!/usr/bin/env python
"""PyTorch (FP32, 元実装と一致するラッパー) と Core ML (FP16) の出力を比較する。

両方の出力を MoGe 元実装の recover_focal_shift で後処理し、深度・FoV・スケールを比べる。
入力画像はアスペクト比で中央クロップしてからモデル入力サイズへリサイズする。

    python compare_moge.py --model ../../Models/MoGe2S.mlpackage --images out/samples/*.jpg
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from moge_wrapper import MoGe2CoreML, add_moge_to_path, load_moge


def center_crop_resize(img: Image.Image, width: int, height: int) -> Image.Image:
    w, h = img.size
    target = width / height
    if w / h > target:
        nw = round(h * target)
        img = img.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = round(w / target)
        img = img.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return img.resize((width, height), Image.BICUBIC)


def postprocess(points_chw: torch.Tensor, mask_hw: torch.Tensor, scale: float, fov_x_deg: float | None = None):
    """MoGeModel.infer の後処理部分（force_projection 込みの z-depth のみ）。"""
    from moge.utils.geometry_torch import recover_focal_shift

    points = points_chw.permute(1, 2, 0).unsqueeze(0).float().clone()   # (1, H, W, 3)
    mask = (mask_hw > 0.5).unsqueeze(0)
    h, w = points.shape[1:3]
    a = w / h
    if fov_x_deg is None:
        focal, shift = recover_focal_shift(points, mask)
    else:
        focal = torch.tensor([a / (1 + a * a) ** 0.5 / math.tan(math.radians(fov_x_deg) / 2)])
        _, shift = recover_focal_shift(points, mask, focal=focal)
    depth = points[..., 2] + shift[..., None, None]
    mask = mask & (depth > 0)
    depth = depth * scale
    return depth[0].numpy(), mask[0].numpy(), float(focal[0]), float(shift[0])


def fov_x_deg_from_focal(focal: float, w: int, h: int) -> float:
    a = w / h
    fx = focal / 2 * (1 + a * a) ** 0.5 / a
    return math.degrees(2 * math.atan(0.5 / fx))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--images", nargs="+", type=Path, required=True)
    ap.add_argument("--json", type=Path, default=None)
    args = ap.parse_args()

    add_moge_to_path()
    moge = load_moge()
    ml = ct.models.MLModel(str(args.model), compute_units=ct.ComputeUnit.ALL)
    inp = ml.get_spec().description.input[0].type.imageType
    W, H = inp.width, inp.height
    wrapper = MoGe2CoreML(moge, H, W).eval()

    rows = []
    for path in args.images:
        img = center_crop_resize(Image.open(path).convert("RGB"), W, H)
        x = torch.from_numpy(np.asarray(img)).permute(2, 0, 1).float().unsqueeze(0) / 255.0
        with torch.no_grad():
            p_t, m_t, s_t = wrapper(x)
        out = ml.predict({"image": img})
        p_c = torch.from_numpy(np.asarray(out["points"]).astype(np.float32))[0]
        m_c = torch.from_numpy(np.asarray(out["mask"]).astype(np.float32))[0, 0]
        s_c = float(np.asarray(out["metric_scale"]).reshape(-1)[0])

        d_t, k_t, f_t, sh_t = postprocess(p_t[0], m_t[0, 0], float(s_t))
        d_c, k_c, f_c, sh_c = postprocess(p_c, m_c, s_c)
        both = k_t & k_c
        rel = np.abs(d_c[both] - d_t[both]) / d_t[both]
        ratio = np.maximum(d_c[both] / d_t[both], d_t[both] / d_c[both])
        # 画像下半分中央（歩行者の足元が来やすい領域）の中央値距離
        sl = (slice(H // 2, H), slice(W // 4, 3 * W // 4))
        kk = both[sl]
        row = {
            "image": path.name,
            "valid_ratio_torch": float(k_t.mean()), "valid_ratio_coreml": float(k_c.mean()),
            "mask_agreement": float((k_t == k_c).mean()),
            "absrel_mean": float(rel.mean()), "absrel_p95": float(np.percentile(rel, 95)),
            "delta1.05": float((ratio < 1.05).mean()), "delta1.25": float((ratio < 1.25).mean()),
            "fov_x_deg_torch": fov_x_deg_from_focal(f_t, W, H), "fov_x_deg_coreml": fov_x_deg_from_focal(f_c, W, H),
            "metric_scale_torch": float(s_t), "metric_scale_coreml": s_c,
            "median_depth_lowerhalf_m_torch": float(np.median(d_t[sl][kk])),
            "median_depth_lowerhalf_m_coreml": float(np.median(d_c[sl][kk])),
            "median_depth_m_torch": float(np.median(d_t[k_t])), "median_depth_m_coreml": float(np.median(d_c[k_c])),
        }
        rows.append(row)
        print(f"{row['image']:24s} AbsRel mean={row['absrel_mean']*100:5.2f}% p95={row['absrel_p95']*100:5.2f}%  "
              f"d<1.05={row['delta1.05']*100:5.1f}%  mask一致={row['mask_agreement']*100:5.1f}%  "
              f"FoVx {row['fov_x_deg_torch']:5.1f}/{row['fov_x_deg_coreml']:5.1f}deg  "
              f"scale {s_t.item():.3f}/{s_c:.3f}  中央値(下半分) {row['median_depth_lowerhalf_m_torch']:5.2f}/{row['median_depth_lowerhalf_m_coreml']:5.2f}m")
    mean = lambda k: float(np.mean([r[k] for r in rows]))
    print(f"\n平均: AbsRel={mean('absrel_mean')*100:.2f}%  delta<1.05={mean('delta1.05')*100:.1f}%  mask一致={mean('mask_agreement')*100:.1f}%")
    if args.json:
        args.json.write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
