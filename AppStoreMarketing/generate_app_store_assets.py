#!/usr/bin/env python3
"""Render localized iPhone App Store artwork from shared Chinese UI captures."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent
SIZE = (1320, 2868)
MEDIUM_IPHONE_SIZE = (1206, 2622)
FONT_EN = "/System/Library/Fonts/SFNS.ttf"
FONT_ZH = "/System/Library/Fonts/Hiragino Sans GB.ttc"

SCREENS = [
    (
        "01-gimbal-position", "#214e58", "#92e3e7",
        ("记住云台位置", "回到上次构图", "适配影石360 Luna 系列相机"),
        ("Save a gimbal angle", "Return to your shot", "For Insta360 Luna series cameras"),
    ),
    (
        "02-interval-shooting", "#283e60", "#a9c8ff",
        ("设定间隔", "开始连续拍摄", "自定义从 1 秒到 60 分钟"),
        ("Set the interval", "Shoot a series", "Choose from 1 second to 60 minutes"),
    ),
    (
        "03-capture-presets", "#3e3a58", "#c7bbf9",
        ("存好常用参数", "轻点就能套用", "为人物、星空和其他场景保存预设"),
        ("Save your settings", "Recall them in a tap", "Keep presets for portraits, night skies and more"),
    ),
    (
        "04-live-activities", "#364844", "#a7e1c9",
        ("锁屏也能看", "连续拍摄状态", "实时活动显示连接、录像和连拍状态"),
        ("See shooting status", "on your Lock Screen", "Live Activities show connection and capture status"),
    ),
]


def font(locale: str, size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    if locale == "zh-Hans":
        return ImageFont.truetype(FONT_ZH, size, index=2 if bold else 0)
    face = ImageFont.truetype(FONT_EN, size)
    face.set_variation_by_name("Semibold" if bold else "Regular")
    return face


def background(glow: str) -> Image.Image:
    width, height = 132, 287
    base = Image.new("RGB", (width, height), "#0c141c")
    light = Image.new("RGB", (width, height), glow)
    mask = Image.new("L", (width, height))
    mask.putdata([
        round(196 * max(0, 1 - (((x - 64) / 94) ** 2 + ((y - 53) / 260) ** 2)))
        for y in range(height) for x in range(width)
    ])
    return Image.composite(light, base, mask).resize(SIZE, Image.Resampling.BICUBIC)


def render(source: Path, locale: str, copy: tuple[str, str, str], glow: str, accent: str) -> Image.Image:
    with Image.open(source) as original:
        if original.size != SIZE:
            raise ValueError(f"{source.name} has size {original.size}, expected {SIZE}")
        screen_width = 1004
        screen_height = round(screen_width * original.height / original.width)
        screen = original.convert("RGB").resize((screen_width, screen_height), Image.Resampling.LANCZOS)
    base = background(glow)
    draw = ImageDraw.Draw(base)
    draw.text((660, 144), "LunaScope", font=font("en", 46, bold=True), fill="#edf6f8", anchor="mm")
    title = font(locale, 112 if locale == "zh-Hans" else 108, bold=True)
    subtitle = font(locale, 43)
    for line, face in [(copy[0], title), (copy[1], title), (copy[2], subtitle)]:
        if draw.textlength(line, font=face) > 1160:
            raise ValueError(f"Headline or subtitle too wide: {line}")
    draw.text((660, 282), copy[0], font=title, fill="#f4f9fa", anchor="mm")
    draw.text((660, 407), copy[1], font=title, fill=accent, anchor="mm")
    draw.text((660, 529), copy[2], font=subtitle, fill="#d9e7ec", anchor="mm")

    x, y, border, radius = (SIZE[0] - screen_width) // 2, 619, 11, 91
    draw.rounded_rectangle(
        (x - border, y - border, x + screen_width + border - 1, y + screen_height + border - 1),
        radius=radius + border, fill="#101416", outline="#71838c", width=2,
    )
    mask = Image.new("L", screen.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width - 1, screen.height - 1), radius=radius, fill=255)
    base.paste(screen, (x, y), mask)
    return base


def main() -> None:
    tile_width, tile_height, gutter = 252, 548, 20
    preview = Image.new("RGB", (4 * tile_width + 5 * gutter, 2 * tile_height + 3 * gutter), "#0c141c")
    for row, locale in enumerate(("zh-Hans", "en")):
        large_output = ROOT / "screenshots" / "iphone-6.9" / locale
        medium_output = ROOT / "screenshots" / "iphone-6.3" / locale
        large_output.mkdir(parents=True, exist_ok=True)
        medium_output.mkdir(parents=True, exist_ok=True)
        for column, (name, glow, accent, chinese, english) in enumerate(SCREENS):
            source = ROOT / "source-screenshots" / f"{name}.png"
            artwork = render(source, locale, chinese if row == 0 else english, glow, accent)
            artwork.save(large_output / f"{name}.png", optimize=True)
            medium_artwork = ImageOps.fit(artwork, MEDIUM_IPHONE_SIZE, Image.Resampling.LANCZOS)
            medium_artwork.save(medium_output / f"{name}.png", optimize=True)
            tile = artwork.resize((tile_width, tile_height), Image.Resampling.LANCZOS)
            preview.paste(tile, (gutter + column * (tile_width + gutter), gutter + row * (tile_height + gutter)))
    previews = ROOT / "previews"
    previews.mkdir(parents=True, exist_ok=True)
    preview.save(previews / "iphone-6.9-contact-sheet.jpg", quality=91, optimize=True)


if __name__ == "__main__":
    main()
