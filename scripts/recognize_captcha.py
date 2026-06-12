#!/usr/bin/env python3
"""Recognize distorted captcha images using ddddocr."""
from __future__ import annotations

import io
import os
import re
import sys
from collections import Counter
from pathlib import Path

from PIL import Image, ImageEnhance, ImageOps


def clean_captcha_text(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "", value).upper()


_OCR_ENGINE = None
_DET_ENGINE = None


def get_ocr_engine():
    global _OCR_ENGINE
    if _OCR_ENGINE is None:
        import ddddocr

        _OCR_ENGINE = ddddocr.DdddOcr(show_ad=False)
    return _OCR_ENGINE


def get_det_engine():
    global _DET_ENGINE
    if _DET_ENGINE is None:
        import ddddocr

        _DET_ENGINE = ddddocr.DdddOcr(det=True, ocr=False, show_ad=False)
    return _DET_ENGINE


def classify_image_bytes(ocr, image_bytes: bytes) -> str:
    result = ocr.classification(image_bytes)
    return clean_captcha_text(result)


def image_to_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def recognize_by_detection(img: Image.Image) -> str:
    """Detect each character box, then classify individually (best for scattered letters)."""
    ocr = get_ocr_engine()
    det = get_det_engine()
    width, height = img.size

    bboxes = det.detection(image_to_bytes(img))
    if not bboxes or len(bboxes) < 3:
        return ""

    chars: list[str] = []
    for box in sorted(bboxes, key=lambda b: b[0]):
        x1, y1, x2, y2 = box
        pad = 2
        crop = img.crop(
            (
                max(0, x1 - pad),
                max(0, y1 - pad),
                min(width, x2 + pad),
                min(height, y2 + pad),
            )
        )
        cw, ch = crop.size
        crop = crop.resize(
            (max(cw * 5, 48), max(ch * 5, 48)),
            Image.Resampling.LANCZOS,
        )
        piece = classify_image_bytes(ocr, image_to_bytes(crop))
        if piece:
            chars.append(piece[0])

    text = "".join(chars)
    if 4 <= len(text) <= 8:
        return text
    return ""


def collect_whole_image_candidates(img: Image.Image) -> list[str]:
    ocr = get_ocr_engine()
    width, height = img.size
    candidates: list[str] = []

    sources: list[Image.Image] = [img]
    sources.append(ImageEnhance.Contrast(img).enhance(2.5))
    sources.append(ImageEnhance.Contrast(img).enhance(3.0))
    gray = ImageOps.autocontrast(img.convert("L")).convert("RGB")
    sources.append(gray)

    for source in sources:
        candidates.append(classify_image_bytes(ocr, image_to_bytes(source)))
        for scale in (2, 3, 4):
            scaled = source.resize(
                (width * scale, height * scale),
                Image.Resampling.LANCZOS,
            )
            candidates.append(classify_image_bytes(ocr, image_to_bytes(scaled)))

    return [c for c in candidates if c]


def pick_best_candidate(candidates: list[str]) -> str:
    if not candidates:
        return ""

    valid = [c for c in candidates if 4 <= len(c) <= 8]
    pool = valid if valid else [c for c in candidates if 3 <= len(c) <= 8]
    if not pool:
        pool = candidates

    # 该站点验证码多为 6 位；同票时优先 6 位结果
    six = [c for c in pool if len(c) == 6]
    if six:
        return Counter(six).most_common(1)[0][0]

    return Counter(pool).most_common(1)[0][0]


def recognize_captcha(path: Path) -> str:
    img = Image.open(path).convert("RGB")

    by_det = recognize_by_detection(img)
    if by_det:
        return by_det

    return pick_best_candidate(collect_whole_image_candidates(img))


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
