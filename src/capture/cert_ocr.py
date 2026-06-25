"""OCR 执业证书编码 from institution capture PNGs."""

from __future__ import annotations

import re
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from rapidocr_onnxruntime import RapidOCR

CERT_LABEL_PATTERN = re.compile(r"执业证书编码[:：]?\s*([0-9A-Za-z]{10,30})")
CERT_FALLBACK_PATTERN = re.compile(r"证书编码[:：]?\s*([0-9A-Za-z]{10,30})")


def normalize_cert_code(value: str | None) -> str:
    if not value:
        return ""
    return re.sub(r"\s+", "", str(value).strip().upper())


def extract_cert_from_text(text: str) -> str | None:
    if not text:
        return None
    compact = re.sub(r"\s+", "", text)
    for pattern in (CERT_LABEL_PATTERN, CERT_FALLBACK_PATTERN):
        match = pattern.search(compact)
        if match:
            return normalize_cert_code(match.group(1))
    for match in re.finditer(r"(?<![\d])(\d{15})(?![\d])", compact):
        token = match.group(1)
        if token.startswith(("19", "20")) and len(token) == 15:
            continue
        return token
    return None


def _load_image(path: Path) -> np.ndarray:
    return np.array(Image.open(path).convert("RGB"))


def _maybe_upscale(region: np.ndarray, min_size: int = 600) -> np.ndarray:
    height, width = region.shape[:2]
    if max(height, width) >= min_size:
        return region
    scale = min_size / max(height, width)
    return cv2.resize(
        region,
        (int(width * scale), int(height * scale)),
        interpolation=cv2.INTER_CUBIC,
    )


def _crop_practice_info_region(image: np.ndarray) -> np.ndarray:
    height, width = image.shape[:2]
    return image[int(height * 0.32) : int(height * 0.92), 0 : int(width * 0.95)]


def _crop_basic_info_region(image: np.ndarray) -> np.ndarray:
    height, width = image.shape[:2]
    return image[int(height * 0.06) : int(height * 0.44), 0 : int(width * 0.78)]


def _run_ocr(engine: RapidOCR, image: np.ndarray) -> tuple[str, float]:
    result, _ = engine(image)
    if not result:
        return "", 0.0
    lines: list[str] = []
    scores: list[float] = []
    for item in result:
        text = str(item[1]).strip()
        score = float(item[2])
        if text:
            lines.append(text)
            scores.append(score)
    if not lines:
        return "", 0.0
    return "\n".join(lines), sum(scores) / len(scores)


def ocr_cert_from_image(engine: RapidOCR, path: Path) -> tuple[str | None, float]:
    image = _load_image(path)
    practice_text, practice_conf = _run_ocr(engine, _maybe_upscale(_crop_practice_info_region(image)))
    best = extract_cert_from_text(practice_text)
    confidences = [practice_conf] if practice_conf > 0 else []

    if not best:
        base_text, base_conf = _run_ocr(engine, _maybe_upscale(_crop_basic_info_region(image)))
        if base_conf > 0:
            confidences.append(base_conf)
        best = extract_cert_from_text(base_text)

    if not best:
        full_text, full_conf = _run_ocr(engine, _maybe_upscale(image))
        if full_conf > 0:
            confidences.append(full_conf)
        best = extract_cert_from_text(full_text)

    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0
    return best, avg_conf


def make_ocr_engine() -> RapidOCR:
    return RapidOCR(use_cls=False)
