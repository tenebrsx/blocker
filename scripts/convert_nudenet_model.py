#!/usr/bin/env python3
"""Builds the body-part detector Word Blocker's Block Log uses to say what an image block was about.

NudeNet v3 (320n, a small YOLOv8n detector) names 18 kinds of body part, each marked exposed or covered
(`FEMALE_BREAST_EXPOSED`, `BUTTOCKS_EXPOSED`, `FACE_MALE`, ...) with a box and a confidence. It runs only after the
screen scanner has already blocked something, to write down what was in the picture; it never decides a block.

This downloads the ONNX weights from the NudeNet GitHub release, checks them against a pinned SHA-256, converts
them to Core ML, and checks the converted model against ONNX Runtime on harmless generated images. ONNX is plain
data, unlike the `.pt` checkpoints, which are pickles that can run code when loaded; only ONNX is used here.

The model is NOT stored in this repository. NudeNet and the Ultralytics YOLOv8 it is trained with are AGPL-3.0:
fine to run on your own Mac, but do not put the converted model in a public release. Run this once:

    python3 -m venv /tmp/nudenet-venv
    /tmp/nudenet-venv/bin/pip install onnx onnx2torch onnxruntime torch coremltools numpy pillow
    /tmp/nudenet-venv/bin/python -I scripts/convert_nudenet_model.py

By default the result is saved to ~/Library/Application Support/WordBlocker/NudeNet.mlpackage, where the app
looks for it (restart the app afterwards).
"""
import argparse
import ast
import hashlib
import os
import sys
import urllib.request

import numpy as np
import onnx
import onnxruntime
import torch
import coremltools as ct
from onnx2torch import convert as onnx_to_torch
from PIL import Image

# NudeNet release "v3.4-weights", asset 320n.onnx (12,150,158 bytes).
ASSET_URL = "https://api.github.com/repos/notAI-tech/NudeNet/releases/assets/176831997"
ASSET_SHA256 = "c15d8273adad2d0a92f014cc69ab2d6c311a06777a55545f2c4eb46f51911f0f"
ASSET_SIZE = 12_150_158
SIZE = 320
DEFAULT_OUT = os.path.expanduser("~/Library/Application Support/WordBlocker/NudeNet.mlpackage")

# The order the model outputs its classes in (also in the ONNX metadata, checked below). Sources/Core/BodyPartLogic.swift
# has the same list.
EXPECTED_LABELS = [
    "FEMALE_GENITALIA_COVERED", "FACE_FEMALE", "BUTTOCKS_EXPOSED", "FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED",
    "MALE_BREAST_EXPOSED", "ANUS_EXPOSED", "FEET_EXPOSED", "BELLY_COVERED", "FEET_COVERED", "ARMPITS_COVERED",
    "ARMPITS_EXPOSED", "FACE_MALE", "BELLY_EXPOSED", "MALE_GENITALIA_EXPOSED", "ANUS_COVERED", "FEMALE_BREAST_COVERED",
    "BUTTOCKS_COVERED",
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(destination):
    print(f"Downloading NudeNet 320n.onnx ({ASSET_SIZE / 1e6:.1f} MB) from the notAI-tech/NudeNet GitHub release...")
    request = urllib.request.Request(ASSET_URL, headers={"Accept": "application/octet-stream", "User-Agent": "wordblocker-setup"})
    with urllib.request.urlopen(request) as response, open(destination, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def harmless_test_images():
    """Generated pictures only: flat colours, gradients and noise, as 0...1 float arrays (1, 3, SIZE, SIZE)."""
    rng = np.random.default_rng(11)
    images = []
    for color in [(0, 0, 0), (255, 255, 255), (200, 40, 40), (40, 160, 90), (222, 184, 135)]:
        images.append(Image.new("RGB", (SIZE, SIZE), color))
    ramp = np.tile(np.linspace(0, 255, SIZE, dtype=np.uint8), (SIZE, 1))
    images.append(Image.fromarray(np.stack([ramp, ramp[::-1], ramp.T], axis=-1)))
    for _ in range(6):
        images.append(Image.fromarray(rng.integers(0, 256, (SIZE, SIZE, 3), dtype=np.uint8)))
    return images


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT, help="where to save the .mlpackage")
    parser.add_argument("--weights", default=None, help="an already downloaded 320n.onnx (it is still checked against the pinned hash)")
    parser.add_argument("--work", default=None, help="folder for the download (default: a new folder next to --out)")
    args = parser.parse_args()

    weights = args.weights
    if weights is None:
        work = args.work or os.path.join(os.path.dirname(os.path.abspath(args.out)), "nudenet-download")
        os.makedirs(work, exist_ok=True)
        weights = os.path.join(work, "320n.onnx")
        if not os.path.exists(weights):
            download(weights)

    size, digest = os.path.getsize(weights), sha256(weights)
    print(f"{weights}: {size} bytes, sha256 {digest}")
    if size != ASSET_SIZE or digest != ASSET_SHA256:
        print("FAILED: this is not the expected NudeNet 320n.onnx (size or SHA-256 differs). Not converting it.")
        sys.exit(1)

    model = onnx.load(weights)
    meta = {entry.key: entry.value for entry in model.metadata_props}
    names = ast.literal_eval(meta["names"])
    labels = [names[i] for i in range(len(names))]
    if labels != EXPECTED_LABELS:
        print(f"FAILED: the model's classes are not the ones this app expects:\n  {labels}")
        sys.exit(1)
    print(f"{len(labels)} classes, input {SIZE}x{SIZE}")

    torch_model = onnx_to_torch(model).eval()
    session = onnxruntime.InferenceSession(weights, providers=["CPUExecutionProvider"])

    def reference(array):
        return session.run(None, {"images": array})[0]

    print("Checking the PyTorch version against ONNX Runtime...")
    for image in harmless_test_images()[:4]:
        array = (np.asarray(image, dtype=np.float32) / 255.0).transpose(2, 0, 1)[None]
        with torch.no_grad():
            got = torch_model(torch.from_numpy(array)).numpy()
        difference = float(np.abs(got - reference(array)).max())
        if difference > 1e-3:
            print(f"FAILED: PyTorch and ONNX Runtime differ by {difference}")
            sys.exit(1)

    print("Converting to Core ML (float32)...")
    traced = torch.jit.trace(torch_model, torch.rand(1, 3, SIZE, SIZE))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), color_layout=ct.colorlayout.RGB, scale=1 / 255.0)],
        outputs=[ct.TensorType(name="detections")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "NudeNet v3 320n body-part detector (AGPL-3.0), converted for Word Blocker's Block Log"
    mlmodel.user_defined_metadata["labels"] = ",".join(labels)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    mlmodel.save(args.out)
    print(f"Saved {args.out}")

    print("Checking the converted model against ONNX Runtime on generated images...")
    worst = 0.0
    for index, image in enumerate(harmless_test_images()):
        array = (np.asarray(image, dtype=np.float32) / 255.0).transpose(2, 0, 1)[None]
        expected = reference(array)[0]                       # (22, 2100)
        got = np.asarray(mlmodel.predict({"image": image})["detections"])[0]
        difference = float(np.abs(expected - got).max())
        worst = max(worst, difference)
        print(f"  image {index:2d}: output {tuple(got.shape)}, highest class score {got[4:].max():.4f} (original {expected[4:].max():.4f}), largest difference {difference:.5f}")

    print(f"Largest difference: {worst:.5f}")
    # Boxes are in pixels (0...320), scores in 0...1, so allow a little more than for the scores alone.
    if worst > 0.05:
        print("FAILED: the converted model does not match the original closely enough.")
        sys.exit(1)
    print("OK: conversion matches the original.")


if __name__ == "__main__":
    main()
