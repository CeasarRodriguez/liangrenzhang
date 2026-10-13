#!/usr/bin/env python3
"""Generates Android / HarmonyOS launcher icons and the in-app logo from
design/icon_foreground.png (transparent PNG of the piggy bank).

Needs Pillow:  python3 -m pip install pillow
Usage:         python3 tools/make-icons.py
"""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "design" / "icon_foreground.png"
BACKGROUND = (255, 241, 230, 255)  # #FFF1E6, matches the app's cream palette

ANDROID_RES = ROOT / "app/android/app/src/main/res"
OHOS_APP_MEDIA = ROOT / "app/ohos/AppScope/resources/base/media"
OHOS_ENTRY_MEDIA = ROOT / "app/ohos/entry/src/main/resources/base/media"

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def subject() -> Image.Image:
    im = Image.open(SRC).convert("RGBA")
    return im.crop(im.getbbox())


def place(subj: Image.Image, size: int, fill: float, bg=None) -> Image.Image:
    """Centers the subject so its longer side covers `fill` of the canvas."""
    canvas = Image.new("RGBA", (size, size), bg or (0, 0, 0, 0))
    scale = size * fill / max(subj.size)
    s = subj.resize((round(subj.width * scale), round(subj.height * scale)), Image.LANCZOS)
    canvas.alpha_composite(s, ((size - s.width) // 2, (size - s.height) // 2))
    return canvas


def main() -> None:
    subj = subject()

    # Android legacy icons (full square, launcher applies its own mask)
    for name, d in DENSITIES.items():
        out = ANDROID_RES / f"mipmap-{name}"
        out.mkdir(parents=True, exist_ok=True)
        place(subj, round(48 * d), 0.80, BACKGROUND).save(out / "ic_launcher.png")
        # adaptive foreground: 108dp canvas, subject inside the 66dp safe zone
        place(subj, round(108 * d), 0.58).save(out / "ic_launcher_foreground.png")

    anydpi = ANDROID_RES / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n'
    )
    values = ANDROID_RES / "values"
    values.mkdir(exist_ok=True)
    r, g, b, _ = BACKGROUND
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">#{r:02X}{g:02X}{b:02X}</color>\n'
        "</resources>\n"
    )

    # HarmonyOS layered icons (1024px foreground/background) + plain icons
    for media in (OHOS_APP_MEDIA, OHOS_ENTRY_MEDIA):
        media.mkdir(parents=True, exist_ok=True)
        place(subj, 1024, 0.62).save(media / "foreground.png")
        Image.new("RGBA", (1024, 1024), BACKGROUND).save(media / "background.png")
        (media / "layered_image.json").write_text(json.dumps(
            {"layered-image": {"background": "$media:background", "foreground": "$media:foreground"}},
            indent=2,
        ) + "\n")
    place(subj, 1024, 0.80, BACKGROUND).save(OHOS_APP_MEDIA / "app_icon.png")
    place(subj, 512, 0.80, BACKGROUND).save(OHOS_ENTRY_MEDIA / "icon.png")

    # in-app logo (login page)
    place(subj, 512, 0.96).save(ROOT / "app/assets/logo.png")
    print("icons generated")


if __name__ == "__main__":
    main()
