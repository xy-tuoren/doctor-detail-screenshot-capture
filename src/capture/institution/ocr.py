"""OCR via direct RapidOCR import — no subprocess, no IPC."""

from __future__ import annotations

import io
import re
from typing import Optional

from PIL import Image

_engine = None

# 详情窗「信息展示」固定比例区域（相对窗口宽/高，与 verify_captures / cert_ocr 一致思路）
# (left, top, right, bottom)
_NAME_REGION = (0.0, 0.14, 0.35, 0.26)
_CERT_REGION = (0.0, 0.72, 0.68, 0.90)
_PRACTICE_REGION = (0.0, 0.32, 0.95, 0.92)


def get_engine():
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _engine = RapidOCR()
    return _engine


def crop_detail_region(
    image: Image.Image,
    region: tuple[float, float, float, float],
) -> Image.Image:
    """按详情窗比例裁剪子区域。region = (left, top, right, bottom) 均为 0~1。"""
    width, height = image.size
    left, top, right, bottom = region
    return image.crop((
        int(width * left),
        int(height * top),
        int(width * right),
        int(height * bottom),
    ))


def _maybe_upscale(image: Image.Image, min_size: int = 480) -> Image.Image:
    width, height = image.size
    if max(width, height) >= min_size:
        return image
    scale = min_size / max(width, height)
    return image.resize(
        (max(1, int(width * scale)), max(1, int(height * scale))),
        Image.LANCZOS,
    )


def recognize_image(image: Image.Image) -> str:
    """Recognize text from a PIL Image. Returns multi-line text."""
    engine = get_engine()
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    buf.seek(0)
    import numpy as np
    arr = np.array(Image.open(buf))
    result, _elapse = engine(arr)
    lines: list[str] = []
    for item in result or []:
        lines.append(str(item[1]))
    return "\n".join(lines)


def _recognize_region(image: Image.Image, region: tuple[float, float, float, float]) -> str:
    cropped = _maybe_upscale(crop_detail_region(image, region))
    return recognize_image(cropped)


def normalize_cert_code(value: str) -> str:
    if not value:
        return ""
    return value.strip().upper().replace(" ", "")


# 机构端详情页标签可能是「编码」或「编号」；OCR 常在标签与号码间多识别一个冒号。
_CERT_PATTERNS = [
    re.compile(r"执业证书编[码号][:：]*([0-9A-Za-z]+)"),
    re.compile(r"(?<!资格)证书编[码号][:：]*([0-9A-Za-z]+)"),
]


def get_cert_code_from_text(text: str) -> Optional[str]:
    if not text or not text.strip():
        return None
    compact = re.sub(r"\s+", "", text)
    for pat in _CERT_PATTERNS:
        m = pat.search(compact)
        if m:
            return normalize_cert_code(m.group(1))
    return None


_NAME_PATTERN = re.compile(
    r"姓名[:：]?([\u4e00-\u9fa5·]{2,4})(?=性别|民族|出生|身份证|资格|执业|医师|$)"
)
_NAME_FALLBACK = re.compile(
    r"姓名\s*[:：]?\s*([\u4e00-\u9fa5·]{2,4})(?=\s*(?:性别|民族|出生|身份证|$))"
)


def get_name_from_text(text: str) -> Optional[str]:
    if not text or not text.strip():
        return None
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    for i, ln in enumerate(lines):
        if re.fullmatch(r"姓名[:：]?", ln) and i > 0:
            prev = lines[i - 1]
            if re.fullmatch(r"[\u4e00-\u9fa5·]{2,4}", prev):
                return prev
        m = re.match(r"姓名[:：]\s*([\u4e00-\u9fa5·]{2,4})", ln)
        if m:
            return m.group(1)
    compact = re.sub(r"\s+", "", text)
    m = _NAME_PATTERN.search(compact)
    if m:
        return m.group(1)
    m2 = _NAME_FALLBACK.search(text)
    if m2:
        return m2.group(1)
    return None


def get_detail_fields_from_text(text: str) -> dict:
    """Extract name and cert code from OCR text."""
    return {
        "name": get_name_from_text(text),
        "certCode": get_cert_code_from_text(text),
    }


def recognize_cert_region(image: Image.Image) -> str:
    """OCR 详情窗执业证书固定区域。"""
    return _recognize_region(image, _CERT_REGION)


def get_cert_code_from_image(image: Image.Image) -> Optional[str]:
    """从详情窗固定区域 OCR 执业证书编号（仅证书窄区，供快速探测）。"""
    text = recognize_cert_region(image)
    if test_loading_text(text):
        return None
    return get_cert_code_from_text(text)


def recognize_detail_fields(
    image: Image.Image,
    *,
    cert_text: str | None = None,
) -> dict:
    """分别 OCR 姓名区与执业证书区；cert_text 可传入以跳过证书区重复 OCR。"""
    name_text = _recognize_region(image, _NAME_REGION)
    if cert_text is None:
        cert_text = _recognize_region(image, _CERT_REGION)
    code = get_cert_code_from_text(cert_text)
    if not code and not test_loading_text(cert_text):
        practice_text = _recognize_region(image, _PRACTICE_REGION)
        if not test_loading_text(practice_text):
            code = get_cert_code_from_text(practice_text)
    return {"name": get_name_from_text(name_text), "certCode": code}


_LOADING_PATTERN = re.compile(
    r"正在查询|正在加载|加载中|请稍[后候]|数据加载|获取最新数据|正在获取|loading|Loading"
)


def test_loading_text(text: str) -> bool:
    if not text or not text.strip():
        return False
    return bool(_LOADING_PATTERN.search(text))
