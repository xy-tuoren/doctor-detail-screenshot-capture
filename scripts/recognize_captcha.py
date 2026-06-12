#!/usr/bin/env python3
"""Recognize distorted captcha images using ddddocr."""
from __future__ import annotations

import io
import os
import re
import sys
from collections import Counter
from pathlib import Path


def clean_captcha_text(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "", value).upper()


_OCR_ENGINE = None


def get_ocr_engine():
    global _OCR_ENGINE
    if _OCR_ENGINE is None:
        import ddddocr

        # 不限制字符集，彩色字母验证码识别率更高
        _OCR_ENGINE = ddddocr.DdddOcr(show_ad=False)
    return _OCR_ENGINE


def classify_image_bytes(ocr, image_bytes: bytes) -> str:
    result = ocr.classification(image_bytes)
    return clean_captcha_text(result)


def recognize_captcha(path: Path) -> str:
    from PIL import Image

    ocr = get_ocr_engine()
    img = Image.open(path).convert("RGB")
    width, height = img.size
    candidates: list[str] = []

    # 原图
    candidates.append(classify_image_bytes(ocr, path.read_bytes()))

    # 仅放大，不做二值化（彩色验证码二值化会严重降准确率）
    for scale in (2, 3, 4):
        scaled = img.resize((width * scale, height * scale), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        scaled.save(buf, format="PNG")
        candidates.append(classify_image_bytes(ocr, buf.getvalue()))

    valid = [c for c in candidates if 4 <= len(c) <= 8]
    if valid:
        return Counter(valid).most_common(1)[0][0]

    valid = [c for c in candidates if 3 <= len(c) <= 8]
    if valid:
        return Counter(valid).most_common(1)[0][0]

    non_empty = [c for c in candidates if c]
    return non_empty[0] if non_empty else ""


def serve() -> None:
    sys.stderr = open(os.devnull, "w")
    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        if path == "__quit__":
            break
        try:
            text = recognize_captcha(Path(path))
        except Exception:
            text = ""
        print(text, flush=True)


def main() -> int:
    if "--serve" in sys.argv:
        serve()
        return 0

    if len(sys.argv) < 2:
        print("usage: recognize_captcha.py <image>|--serve", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"file not found: {path}", file=sys.stderr)
        return 1

    try:
        text = recognize_captcha(path)
    except ImportError:
        print("ddddocr not installed. Run scripts/setup-ocr-env.ps1 first.", file=sys.stderr)
        return 1

    if text:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
