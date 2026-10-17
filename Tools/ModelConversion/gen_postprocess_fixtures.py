#!/usr/bin/env python
"""MoGePostprocess.swift の検証用フィクスチャを書き出す。

Core ML の実出力（サンプル画像）を小さな格子に nearest で間引き、MoGe 公式の recover_focal_shift
（PyTorch + scipy）で得た期待値を JSON に記録する。Swift 側テストは同じ入力から期待値を再現できるかを確かめる。

    python gen_postprocess_fixtures.py --model ../../Models/MoGe2S.mlpackage \
        --images out/samples/london_portrait.jpg out/samples/charles_bridge.jpg \
        --out ../../Packages/RouteDanceCore/Tests/RouteDanceCoreTests/Fixtures/MoGe
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

from compare_moge import center_crop_resize, fov_x_deg_from_focal
from moge_wrapper import add_moge_to_path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--images", nargs="+", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--fix-width", type=int, default=72, help="フィクスチャに保存する幅（nearest で間引く）")
    ap.add_argument("--fix-height", type=int, default=96)
    ap.add_argument("--known-fov-x", type=float, default=65.0, help="既知FoVモードの検証に使う水平画角（度）")
    args = ap.parse_args()

    add_moge_to_path()
    from moge.utils.geometry_torch import recover_focal_shift

    ml = ct.models.MLModel(str(args.model), compute_units=ct.ComputeUnit.ALL)
    t = ml.get_spec().description.input[0].type.imageType
    W, H = t.width, t.height
    fw, fh = args.fix_width, args.fix_height
    args.out.mkdir(parents=True, exist_ok=True)

    # 間引き添字（PyTorch nearest と同じ floor(i * in / out)）
    xs = np.floor(np.arange(fw) * (W / fw)).astype(int)
    ys = np.floor(np.arange(fh) * (H / fh)).astype(int)

    cases = []
    for path in args.images:
        img = center_crop_resize(Image.open(path).convert("RGB"), W, H)
        out = ml.predict({"image": img})
        pts = np.asarray(out["points"], dtype=np.float32)[0][:, ys][:, :, xs]      # (3, fh, fw)
        msk = np.asarray(out["mask"], dtype=np.float32)[0, 0][ys][:, xs]           # (fh, fw)
        scale = float(np.asarray(out["metric_scale"]).reshape(-1)[0])

        points_t = torch.from_numpy(pts).permute(1, 2, 0).unsqueeze(0).contiguous()   # (1, fh, fw, 3)
        mask_t = torch.from_numpy(msk > 0.5).unsqueeze(0)
        a = fw / fh

        focal, shift = recover_focal_shift(points_t, mask_t)
        focal, shift = float(focal[0]), float(shift[0])
        fov_known = args.known_fov_x
        focal_k = torch.tensor([a / (1 + a * a) ** 0.5 / math.tan(math.radians(fov_known) / 2)])
        _, shift_k = recover_focal_shift(points_t, mask_t, focal=focal_k)
        shift_k = float(shift_k[0])

        def depth_of(sh: float) -> np.ndarray:
            d = (pts[2] + sh) * scale
            ok = (msk > 0.5) & ((pts[2] + sh) > 0)
            return np.where(ok, d, np.nan)

        d_est = depth_of(shift)
        d_known = depth_of(shift_k)
        probe = [(x, y) for y in range(8, fh, 16) for x in range(6, fw, 12)]
        name = path.stem
        (pts.astype("<f4").tobytes() + msk.astype("<f4").tobytes())
        (args.out / f"{name}.bin").write_bytes(pts.astype("<f4").tobytes() + msk.astype("<f4").tobytes())
        cases.append({
            "name": name,
            "bin": f"{name}.bin",
            "width": fw, "height": fh,
            "metric_scale": scale,
            "estimate": {
                "focal": focal, "shift": shift,
                "fov_x_deg": fov_x_deg_from_focal(focal, fw, fh),
                "valid_count": int(np.isfinite(d_est).sum()),
                "probes": [{"x": x, "y": y, "depth": None if np.isnan(d_est[y, x]) else float(d_est[y, x])} for x, y in probe],
            },
            "known_fov": {
                "fov_x_deg": fov_known, "shift": shift_k,
                "valid_count": int(np.isfinite(d_known).sum()),
                "probes": [{"x": x, "y": y, "depth": None if np.isnan(d_known[y, x]) else float(d_known[y, x])} for x, y in probe],
            },
        })
        print(name, "focal", focal, "shift", shift, "fov_x", cases[-1]["estimate"]["fov_x_deg"], "scale", scale)

    (args.out / "cases.json").write_text(json.dumps({"layout": "float32 little-endian: points CHW (3,H,W) then mask (H,W)", "cases": cases}, indent=1))


if __name__ == "__main__":
    main()
