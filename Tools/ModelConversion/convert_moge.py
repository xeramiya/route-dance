#!/usr/bin/env python
"""MoGe-2 ViT-S (normal版) を Core ML (mlprogram, FP16) に変換する。

使い方:
    python convert_moge.py --height 504 --width 378 --out ../../Models/MoGe2S.mlpackage
    python convert_moge.py --height 378 --width 504 --out ../../Models/MoGe2S_landscape.mlpackage

入力  : image   (1, 3, H, W) RGB, 0..255 の ImageType（モデル内で /255 と ImageNet 正規化を行う）
出力  : points  (1, 3, h, w) FP32  アフィン不変の点群 [x, y, z]（OpenCV系: x右, y下, z前）
        mask    (1, 1, h, w) FP32  有効画素の確率（0..1）
        metric_scale (1, 1)  FP32  メトリックスケール（メートル）
focal/shift の復元はモデルに含めず Swift (MoGePostprocess.swift) で行う。
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from moge_wrapper import MoGe2CoreML, load_moge

TARGETS = {"iOS17": ct.target.iOS17, "iOS18": ct.target.iOS18}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--height", type=int, default=504)
    ap.add_argument("--width", type=int, default=378)
    ap.add_argument("--out-height", type=int, default=None, help="出力マップの高さ（既定は入力と同じ）")
    ap.add_argument("--out-width", type=int, default=None)
    ap.add_argument("--target", choices=TARGETS, default="iOS18")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    moge = load_moge()
    wrapper = MoGe2CoreML(moge, args.height, args.width, args.out_height, args.out_width).eval()
    example = torch.rand(1, 3, args.height, args.width)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, args.height, args.width),
                scale=1 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[
            ct.TensorType(name="points", dtype=np.float32),
            ct.TensorType(name="mask", dtype=np.float32),
            ct.TensorType(name="metric_scale", dtype=np.float32),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=TARGETS[args.target],
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = "MoGe-2 ViT-S (microsoft/MoGe, MIT). Affine-invariant point map + mask + metric scale."
    mlmodel.author = "Converted from Ruicheng/moge-2-vits-normal"
    mlmodel.license = "MIT"
    mlmodel.user_defined_metadata["moge.input_height"] = str(args.height)
    mlmodel.user_defined_metadata["moge.input_width"] = str(args.width)
    mlmodel.user_defined_metadata["moge.output_height"] = str(wrapper.out_size[0])
    mlmodel.user_defined_metadata["moge.output_width"] = str(wrapper.out_size[1])
    mlmodel.user_defined_metadata["moge.postprocess"] = "recover_focal_shift (Swift: MoGePostprocess)"

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))
    print(json.dumps({"saved": str(args.out), "input": [args.height, args.width], "output": list(wrapper.out_size)}))


if __name__ == "__main__":
    main()
