#!/usr/bin/env python3
"""Recognize institution detail-window screenshots using rapidocr.

Used by capture-doctor-details.ps1 to replace WinRT OCR, which misreads
Chinese characters on this UI (e.g. "编码" -> "编玛").

Serve mode: read image paths from stdin (one per line), print recognized
text to stdout (one line per image). Send "__quit__" to stop.
Single mode: recognize_detail.py <image>  -> prints full text.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_ENGINE = None


def get_engine():
    global _ENGINE
    if _ENGINE is None:
        from rapidocr_onnxruntime import RapidOCR

        _ENGINE = RapidOCR()
    return _ENGINE


def recognize_image(path: Path) -> str:
    engine = get_engine()
    result, _elapse = engine(str(path))
    lines = []
    for item in result or []:
        # item: [box, text, score]
        try:
            lines.append(str(item[1]))
        except Exception:
            pass
    return "\n".join(lines)


def serve() -> None:
    sys.stderr = open(os.devnull, "w")
    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        if path == "__quit__":
            break
        try:
            text = recognize_image(Path(path))
        except Exception:
            text = ""
        # 单行 JSON 输出，避免多行文本与 PS1 ReadLine 协议错位
        print(json.dumps(text, ensure_ascii=False), flush=True)


def main() -> int:
    if "--serve" in sys.argv:
        serve()
        return 0

    if len(sys.argv) < 2:
        print("usage: recognize_detail.py <image>|--serve", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"file not found: {path}", file=sys.stderr)
        return 1

    try:
        text = recognize_image(path)
    except ImportError:
        print("rapidocr_onnxruntime not installed. pip install rapidocr-onnxruntime", file=sys.stderr)
        return 1

    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
