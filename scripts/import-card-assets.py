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


def contents_json(filename: str) -> dict:
    return {
        "images": [
            {
                "filename": filename,
                "idiom": "universal",
                "scale": "1x",
            }
        ],
        "info": {
            "author": "xcode",
            "version": 1,
        },
    }


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
        write_json(image_set / "Contents.json", contents_json(output_name))

    print(f"Imported {len(expected_cards())} card assets into {args.output}")


if __name__ == "__main__":
    main()
