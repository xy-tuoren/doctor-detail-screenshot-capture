"""OCR via direct RapidOCR import — no subprocess, no IPC."""

from __future__ import annotations

import io
import re
from typing import Optional

from PIL import Image

_engine = None


def get_engine():
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _engine = RapidOCR()
    return _engine


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


def normalize_cert_code(value: str) -> str:
    if not value:
        return ""
    return value.strip().upper().replace(" ", "")


_CERT_PATTERNS = [
    re.compile(r"执业证书编码[:：]?([0-9A-Za-z]+)"),
    re.compile(r"证书编码[:：]?([0-9A-Za-z]+)"),
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


_NAME_PATTERN = re.compile(r"姓名[:：]?([\u4e00-\u9fa5·]{2,8})")
_NAME_FALLBACK = re.compile(r"姓名\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})")


def get_detail_fields_from_text(text: str) -> dict:
    """Extract name and cert code from OCR text."""
    name = None
    code = None
    if text and text.strip():
        compact = re.sub(r"\s+", "", text)
        m = _NAME_PATTERN.search(compact)
        if m:
            name = m.group(1)
        if not name:
            m2 = _NAME_FALLBACK.search(text)
            if m2:
                name = m2.group(1)
        code = get_cert_code_from_text(text)
    return {"name": name, "certCode": code}


_LOADING_PATTERN = re.compile(
    r"正在查询|正在加载|加载中|请稍[后候]|数据加载|获取最新数据|正在获取|loading|Loading"
)


def test_loading_text(text: str) -> bool:
    if not text or not text.strip():
        return False
    return bool(_LOADING_PATTERN.search(text))
