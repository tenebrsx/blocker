#!/usr/bin/env python3
"""Builds the image model for Word Blocker's screen scanner.

Downloads Falconsai/nsfw_image_detection (a ViT image classifier, Apache-2.0) from Hugging Face, converts it
to Core ML, and checks the converted model against the original on harmless generated images.

The model is NOT stored in this repository (it is a few hundred MB). Run this once to create it:

    python3 -m venv /tmp/nsfw-venv
    /tmp/nsfw-venv/bin/pip install torch transformers coremltools pillow numpy huggingface_hub
    /tmp/nsfw-venv/bin/python scripts/convert_nsfw_model.py

By default the result is saved to ~/Library/Application Support/WordBlocker/NSFW.mlpackage, where the app
looks for it. Only the safetensors weights are downloaded (never a pickled .bin file).
"""
import argparse
import json
import os
import sys

import numpy as np
import torch
import coremltools as ct
from huggingface_hub import snapshot_download
from PIL import Image
from transformers import ViTForImageClassification

REPO = "Falconsai/nsfw_image_detection"
DEFAULT_OUT = os.path.expanduser("~/Library/Application Support/WordBlocker/NSFW.mlpackage")


class Wrapper(torch.nn.Module):
    """Takes pixels in 0...255, applies the model's own normalisation, returns class probabilities."""

    def __init__(self, model, mean, std):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1) * 255.0)
        self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1) * 255.0)

    def forward(self, pixels):
        logits = self.model(pixel_values=(pixels - self.mean) / self.std).logits
        return torch.softmax(logits, dim=-1)


def harmless_test_images(size):
    """Generated pictures only: flat colours, gradients and noise."""
    rng = np.random.default_rng(7)
    images = []
    for color in [(0, 0, 0), (255, 255, 255), (200, 40, 40), (40, 160, 90), (30, 60, 200), (222, 184, 135)]:
        images.append(Image.new("RGB", (size, size), color))
    ramp = np.tile(np.linspace(0, 255, size, dtype=np.uint8), (size, 1))
    images.append(Image.fromarray(np.stack([ramp, ramp[::-1], ramp.T], axis=-1)))
    for _ in range(6):
        images.append(Image.fromarray(rng.integers(0, 256, (size, size, 3), dtype=np.uint8)))
    return images


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT, help="where to save the .mlpackage")
    parser.add_argument("--cache", default=None, help="Hugging Face download cache folder")
    args = parser.parse_args()

    print(f"Downloading {REPO} (safetensors weights only)...")
    path = snapshot_download(
        REPO, allow_patterns=["config.json", "preprocessor_config.json", "model.safetensors"], cache_dir=args.cache
    )

    with open(os.path.join(path, "preprocessor_config.json")) as handle:
        prep = json.load(handle)
    size = prep["size"]["height"] if isinstance(prep["size"], dict) else int(prep["size"])
    mean, std = prep["image_mean"], prep["image_std"]
    print(f"Input size {size}x{size}, mean {mean}, std {std}")

    model = ViTForImageClassification.from_pretrained(path, use_safetensors=True, attn_implementation="eager").eval()
    labels = [model.config.id2label[i] for i in range(len(model.config.id2label))]
    print(f"Classes: {labels}")

    wrapped = Wrapper(model, mean, std).eval()
    traced = torch.jit.trace(wrapped, torch.rand(1, 3, size, size) * 255.0)

    print("Converting to Core ML (float16)...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), color_layout=ct.colorlayout.RGB, scale=1.0)],
        classifier_config=ct.ClassifierConfig(labels),
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = f"{REPO} ({'/'.join(labels)}), converted for Word Blocker"
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    mlmodel.save(args.out)
    print(f"Saved {args.out}")

    print("Checking the converted model against the original on generated images...")
    worst = 0.0
    for index, image in enumerate(harmless_test_images(size)):
        pixels = torch.from_numpy(np.asarray(image, dtype=np.float32)).permute(2, 0, 1).unsqueeze(0)
        with torch.no_grad():
            expected = wrapped(pixels)[0].numpy()
        predicted = mlmodel.predict({"image": image})
        probabilities = predicted[[k for k in predicted if k.endswith("_probs") or k == "classLabel_probs"][0]]
        got = np.array([probabilities[label] for label in labels])
        difference = float(np.abs(expected - got).max())
        worst = max(worst, difference)
        print(f"  image {index:2d}: original {np.round(expected, 3)}  core ml {np.round(got, 3)}  diff {difference:.4f}")

    print(f"Largest difference: {worst:.4f}")
    if worst > 0.03:
        print("FAILED: the converted model does not match the original closely enough.")
        sys.exit(1)
    print("OK: conversion matches the original.")


if __name__ == "__main__":
    main()
