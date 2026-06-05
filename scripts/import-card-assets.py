#!/usr/bin/env python3
"""Generate app-ready card imagesets from the source scan folder."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from PIL import Image


RANKS = ["1", "2", "3", "4", "5", "7", "8", "9", "10", "11", "15", "30", "40"]
COLORS = ["r", "y", "b", "g"]
SPECIALS = ["tiger", "bull", "bear", "back"]


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def normalize_card(source: Path, destination: Path, size: tuple[int, int]) -> None:
    image = Image.open(source).convert("RGB")
    image.thumbnail(size, Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", size, "white")
    x = (size[0] - image.width) // 2
    y = (size[1] - image.height) // 2
    canvas.paste(image, (x, y))
    canvas.save(destination, optimize=True)


def normalize_mini_card(source: Path, destination: Path, size: tuple[int, int]) -> None:
    image = Image.open(source).convert("RGB")
    width, height = image.size

    # The mini chips are too small for full-card art. Crop the top-left index
    # block instead; it keeps the real-card typography while staying readable.
    crop = image.crop((
        0,
        0,
        int(width * 0.42),
        int(height * 0.17),
    ))
    crop.thumbnail(size, Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", size, "white")
    x = (size[0] - crop.width) // 2
    y = (size[1] - crop.height) // 2
    canvas.paste(crop, (x, y))
    canvas.save(destination, optimize=True)


def write_image_contents_json(path: Path, filename: str) -> None:
    path.write_text(
        "{\n"
        "  \"images\" : [\n"
        "    {\n"
        f"      \"filename\" : \"{filename}\",\n"
        "      \"idiom\" : \"universal\",\n"
        "      \"scale\" : \"1x\"\n"
        "    },\n"
        "    {\n"
        "      \"idiom\" : \"universal\",\n"
        "      \"scale\" : \"2x\"\n"
        "    },\n"
        "    {\n"
        "      \"idiom\" : \"universal\",\n"
        "      \"scale\" : \"3x\"\n"
        "    }\n"
        "  ],\n"
        "  \"info\" : {\n"
        "    \"author\" : \"xcode\",\n"
        "    \"version\" : 1\n"
        "  }\n"
        "}\n"
    )


def expected_cards() -> list[str]:
    colored = [f"{color}{rank}" for color in COLORS for rank in RANKS]
    return colored + SPECIALS


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="cards", type=Path)
    parser.add_argument(
        "--output",
        default=Path("Make-A-Million/Assets.xcassets/Cards"),
        type=Path,
    )
    parser.add_argument("--width", default=468, type=int)
    parser.add_argument("--height", default=720, type=int)
    parser.add_argument("--mini-width", default=152, type=int)
    parser.add_argument("--mini-height", default=104, type=int)
    args = parser.parse_args()

    missing = [name for name in expected_cards() if not (args.source / f"{name}.png").exists()]
    if missing:
        raise SystemExit("Missing card source images: " + ", ".join(missing))

    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True)
    write_json(
        args.output / "Contents.json",
        {"info": {"author": "xcode", "version": 1}},
    )

    for source_name in expected_cards():
        asset_name = f"card_{source_name}"
        image_set = args.output / f"{asset_name}.imageset"
        image_set.mkdir()

        output_name = f"{asset_name}.png"
        normalize_card(
            args.source / f"{source_name}.png",
            image_set / output_name,
            (args.width, args.height),
        )
        write_image_contents_json(image_set / "Contents.json", output_name)

        mini_asset_name = f"mini_card_{source_name}"
        mini_image_set = args.output / f"{mini_asset_name}.imageset"
        mini_image_set.mkdir()

        mini_output_name = f"{mini_asset_name}.png"
        normalize_mini_card(
            args.source / f"{source_name}.png",
            mini_image_set / mini_output_name,
            (args.mini_width, args.mini_height),
        )
        write_image_contents_json(mini_image_set / "Contents.json", mini_output_name)

    print(f"Imported {len(expected_cards())} card assets and mini assets into {args.output}")


if __name__ == "__main__":
    main()
