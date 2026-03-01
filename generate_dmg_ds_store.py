#!/usr/bin/env python3
"""
Generate a deterministic DMG .DS_Store layout file without Finder/AppleScript.

Requires:
  pip install ds-store
"""

from __future__ import annotations

import argparse
import os
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate DMG .DS_Store layout.")
    parser.add_argument(
        "--output",
        default="assets/dmg/.DS_Store",
        help="Output .DS_Store path (default: assets/dmg/.DS_Store)",
    )
    parser.add_argument(
        "--app-name",
        default="orcv.app",
        help='App bundle filename as it appears in DMG root (default: "orcv.app")',
    )
    parser.add_argument("--window-left", type=int, default=120)
    parser.add_argument("--window-top", type=int, default=120)
    parser.add_argument("--window-width", type=int, default=520)
    parser.add_argument("--window-height", type=int, default=300)
    parser.add_argument("--icon-size", type=int, default=160)
    parser.add_argument("--text-size", type=int, default=12)
    parser.add_argument("--grid-spacing", type=int, default=84)
    parser.add_argument(
        "--icon-center-gap",
        type=int,
        default=220,
        help="Fixed center-to-center horizontal gap between Applications and app icon",
    )
    parser.add_argument(
        "--icon-center-y",
        type=int,
        default=120,
        help="Fixed icon center Y position",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        from ds_store import DSStore
    except Exception:
        print(
            "error: missing Python dependency 'ds_store'.\n"
            "install with: python3 -m pip install ds-store",
            file=sys.stderr,
        )
        return 1

    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    window_bounds = (
        f"{{{{{args.window_left}, {args.window_top}}}, "
        f"{{{args.window_width}, {args.window_height}}}}}"
    )

    bwsp = {
        "ShowStatusBar": False,
        "WindowBounds": window_bounds,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 180,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }

    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 0,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": float(args.grid_spacing),
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": float(args.text_size),
        "iconSize": float(args.icon_size),
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    center_x = args.window_width / 2.0
    applications_x = int(round(center_x - args.icon_center_gap / 2.0))
    app_x = int(round(center_x + args.icon_center_gap / 2.0))
    icon_center_y = int(round(args.icon_center_y))

    with DSStore.open(args.output, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = bwsp
        store["."]["icvp"] = icvp
        store["."]["icvl"] = ("type", b"icnv")
        store[args.app_name]["Iloc"] = (applications_x, icon_center_y)
        store["Applications"]["Iloc"] = (app_x, icon_center_y)

    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
