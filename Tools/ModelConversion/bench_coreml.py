#!/usr/bin/env python
"""Core ML モデルのレイテンシ計測と MLComputePlan によるデバイス割り当て確認（macOS 14.4+）。"""
import argparse, time, statistics, collections
import numpy as np
import coremltools as ct
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--iters", type=int, default=30)
ap.add_argument("--plan", action="store_true")
a = ap.parse_args()

UNITS = {"all": ct.ComputeUnit.ALL, "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
         "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU, "cpuOnly": ct.ComputeUnit.CPU_ONLY}

for name, cu in UNITS.items():
    t0 = time.time()
    m = ct.models.MLModel(a.model, compute_units=cu)
    spec = m.get_spec()
    inp = spec.description.input[0]
    h, w = inp.type.imageType.height, inp.type.imageType.width
    img = Image.fromarray((np.random.rand(h, w, 3) * 255).astype(np.uint8))
    m.predict({"image": img})  # warmup / compile
    load = time.time() - t0
    ts = []
    n = a.iters if name != "cpuOnly" else 5
    for _ in range(n):
        t = time.perf_counter(); m.predict({"image": img}); ts.append((time.perf_counter() - t) * 1000)
    print(f"{name:20s} {w}x{h} load+first={load:5.1f}s  median={statistics.median(ts):7.1f}ms  min={min(ts):7.1f}  p90={sorted(ts)[int(len(ts)*0.9)-1]:7.1f}")

if a.plan:
    from coremltools.models.compute_plan import MLComputePlan
    from coremltools.models.compute_device import MLNeuralEngineComputeDevice
    import coremltools.models.compute_device as cd
    compiled = ct.models.utils.compile_model(ct.models.MLModel(a.model, skip_model_load=True).get_spec() and a.model) if False else None
    mc = ct.utils.compile_model(a.model) if hasattr(ct, "utils") and hasattr(ct.utils, "compile_model") else ct.models.utils.compile_model(a.model)
    for name in ["all", "cpuAndNeuralEngine"]:
        plan = MLComputePlan.load_from_path(mc, compute_units=UNITS[name])
        prog = plan.model_structure.program
        fn = prog.functions["main"]
        cnt = collections.Counter(); unsupported = collections.Counter()
        for op in fn.block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            if usage is None:
                continue
            dev = type(usage.preferred_compute_device).__name__.replace("ML", "").replace("ComputeDevice", "")
            cnt[dev] += 1
            if dev != "NeuralEngine":
                unsupported[(op.operator_name, dev)] += 1
        print(f"\n[{name}] preferred device per op: {dict(cnt)}  (total {sum(cnt.values())})")
        for (o, d), c in unsupported.most_common(12):
            print(f"   non-ANE: {o:28s} {d:10s} x{c}")
