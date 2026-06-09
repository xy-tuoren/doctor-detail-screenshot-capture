#!/usr/bin/env python3
"""Verify capture PNG filenames against OCR-extracted name and ID card."""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from rapidocr_onnxruntime import RapidOCR


# 同时匹配 18 位（含 X 结尾）与 15 位老身份证号
ID_CARD_PATTERN = re.compile(r"(?<![\dXx])(?:\d{17}[\dXx]|\d{15})(?![\dXx])")
NAME_PATTERNS = [
    re.compile(r"姓名[:：]?\s*([\u4e00-\u9fa5·]{2,8})(?=性别|民族|出生|身份证|医师|$)"),
    re.compile(r"姓名[:：]?\s*([\u4e00-\u9fa5·]{2,8})"),
]
STANDALONE_NAME_PATTERN = re.compile(r"^[\u4e00-\u9fa5·]{2,4}$")
NAME_FIELD_SUFFIXES = ("性别", "民族", "出生日期", "出生", "身份证", "医师照片", "医师")
NOT_NAME_TOKENS = frozenset(
    {
        "性别",
        "民族",
        "姓名",
        "出生",
        "汉族",
        "男",
        "女",
        "基本信息",
        "执业信息",
        "信息展示",
        "医师照片",
        "出生日期",
        "身份证号",
        "请求更正",
    }
)
FILENAME_PATTERN = re.compile(r"^(.+)_(.{15,18})$")

REPORT_COLUMNS = {
    "file": "文件路径",
    "subfolder": "子目录",
    "expected_name": "文件名姓名",
    "expected_id_card": "文件名身份证",
    "ocr_name": "OCR识别姓名",
    "ocr_id_card": "OCR识别身份证",
    "name_match": "姓名比对",
    "id_match": "身份证比对",
    "overall": "总体结论",
    "ocr_confidence": "OCR置信度",
    "notes": "备注",
}

MATCH_LABELS = {
    "OK": "一致",
    "MISMATCH": "不一致",
    "MISSING": "未识别",
    "N/A": "不适用",
}

OVERALL_LABELS = {
    "OK": "通过",
    "NAME_MISMATCH": "姓名不匹配",
    "ID_MISMATCH": "身份证不匹配",
    "BOTH_MISMATCH": "姓名和身份证均不匹配",
    "BAD_FILENAME": "文件名格式错误",
}


@dataclass
class ExpectedInfo:
    name: str
    id_card: str


@dataclass
class OcrInfo:
    name: str | None
    id_card: str | None
    text: str
    confidence: float
    name_candidates: list[str]


@dataclass
class VerifyResult:
    file: str
    subfolder: str
    expected_name: str
    expected_id_card: str
    ocr_name: str
    ocr_id_card: str
    name_match: str
    id_match: str
    overall: str
    ocr_confidence: str
    notes: str


def normalize_id_card(value: str | None) -> str:
    if not value:
        return ""
    return value.strip().upper().replace(" ", "")


def normalize_name(value: str | None) -> str:
    if not value:
        return ""
    return value.strip().replace(" ", "")


def clean_extracted_name(value: str | None) -> str | None:
    if not value:
        return None
    name = normalize_name(value)
    for suffix in NAME_FIELD_SUFFIXES:
        idx = name.find(suffix)
        if idx > 0:
            name = name[:idx]
    match = re.fullmatch(r"[\u4e00-\u9fa5·]{2,8}", name)
    if match:
        return name
    match = re.match(r"([\u4e00-\u9fa5·]{2,8})", name)
    if match:
        return match.group(1)
    return None


def extract_name_candidates(text: str) -> list[str]:
    if not text:
        return []

    compact = re.sub(r"\s+", "", text)
    candidates: list[str] = []

    for pattern in NAME_PATTERNS:
        for match in pattern.finditer(compact):
            cleaned = clean_extracted_name(match.group(1))
            if cleaned:
                candidates.append(cleaned)

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for index, line in enumerate(lines):
        compact_line = re.sub(r"\s+", "", line)
        if "姓名" not in compact_line:
            continue
        inline = re.search(
            r"姓名[:：]?\s*([\u4e00-\u9fa5·]{2,8})(?=性别|民族|出生|身份证|$)",
            compact_line,
        )
        if inline:
            cleaned = clean_extracted_name(inline.group(1))
            if cleaned:
                candidates.append(cleaned)
        for next_line in lines[index + 1 : index + 4]:
            if (
                STANDALONE_NAME_PATTERN.fullmatch(next_line)
                and next_line not in NOT_NAME_TOKENS
            ):
                candidates.append(next_line)

    for line in lines:
        if STANDALONE_NAME_PATTERN.fullmatch(line) and line not in NOT_NAME_TOKENS:
            candidates.append(line)

    deduped: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            deduped.append(candidate)
    return deduped


def parse_filename(path: Path) -> ExpectedInfo | None:
    match = FILENAME_PATTERN.match(path.stem)
    if not match:
        return None
    return ExpectedInfo(name=match.group(1), id_card=normalize_id_card(match.group(2)))


def load_image(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    return np.array(image)


def maybe_upscale(region: np.ndarray, min_size: int = 600) -> np.ndarray:
    height, width = region.shape[:2]
    if max(height, width) >= min_size:
        return region
    scale = min_size / max(height, width)
    return cv2.resize(
        region,
        (int(width * scale), int(height * scale)),
        interpolation=cv2.INTER_CUBIC,
    )


def crop_basic_info_region(image: np.ndarray) -> np.ndarray:
    """基本信息整块：同时包含姓名与身份证号，单次 OCR 即可。"""
    height, width = image.shape[:2]
    return image[int(height * 0.06) : int(height * 0.44), 0 : int(width * 0.78)]


def crop_name_region(image: np.ndarray) -> np.ndarray:
    """姓名补扫区（仅在整块未识别到姓名时使用）。"""
    height, width = image.shape[:2]
    return image[int(height * 0.08) : int(height * 0.32), 0 : int(width * 0.55)]


def crop_id_card_region(image: np.ndarray) -> np.ndarray:
    """身份证补扫区（仅在整块未识别到身份证时使用）。"""
    height, width = image.shape[:2]
    return image[int(height * 0.26) : int(height * 0.42), 0 : int(width * 0.75)]


def run_ocr(engine: RapidOCR, image: np.ndarray) -> tuple[str, float]:
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
    avg_score = sum(scores) / len(scores)
    return "\n".join(lines), avg_score


def extract_id_from_text(text: str) -> str | None:
    if not text:
        return None
    for source in (text, re.sub(r"\s+", "", text)):
        matches = ID_CARD_PATTERN.findall(source)
        if matches:
            eighteen = [m for m in matches if len(m) == 18]
            chosen = eighteen[0] if eighteen else matches[0]
            return normalize_id_card(chosen)
    return None


def extract_fields(text: str) -> tuple[str | None, str | None]:
    if not text:
        return None, None

    name_candidates = extract_name_candidates(text)
    name = name_candidates[0] if name_candidates else None
    id_card = extract_id_from_text(text)
    return name, id_card


def ocr_image(engine: RapidOCR, path: Path) -> OcrInfo:
    image = load_image(path)

    # 默认一次 OCR：基本信息整块同时含姓名与身份证号
    base_text, base_conf = run_ocr(engine, maybe_upscale(crop_basic_info_region(image)))
    texts = [base_text] if base_text else []
    confidences = [base_conf] if base_conf > 0 else []

    name_candidates = extract_name_candidates(base_text)
    best_id = extract_id_from_text(base_text)

    # 仅在缺失时补扫对应小区域，避免不必要的推理
    if not name_candidates:
        name_text, name_conf = run_ocr(engine, maybe_upscale(crop_name_region(image)))
        if name_text:
            texts.append(name_text)
            if name_conf > 0:
                confidences.append(name_conf)
            name_candidates = extract_name_candidates(name_text)

    if not best_id:
        id_text, id_conf = run_ocr(engine, maybe_upscale(crop_id_card_region(image)))
        if id_text:
            texts.append(id_text)
            if id_conf > 0:
                confidences.append(id_conf)
            best_id = extract_id_from_text(id_text)

    best_name = name_candidates[0] if name_candidates else None
    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0
    full_text = "\n".join(texts)

    return OcrInfo(
        name=best_name,
        id_card=best_id,
        text=full_text,
        confidence=avg_conf,
        name_candidates=name_candidates,
    )


def pick_best_name(candidates: list[str], expected: str | None) -> str | None:
    if not candidates:
        return None
    if expected:
        expected_norm = normalize_name(expected)
        for candidate in candidates:
            if normalize_name(candidate) == expected_norm:
                return candidate
        for candidate in candidates:
            candidate_norm = normalize_name(candidate)
            if expected_norm in candidate_norm or candidate_norm in expected_norm:
                return candidate
    return candidates[0]


def compare_name(expected: str, actual: str | None) -> tuple[str, str]:
    expected_norm = normalize_name(expected)
    actual_norm = normalize_name(clean_extracted_name(actual))
    if not actual_norm:
        return "MISSING", "OCR 未识别到姓名"
    if expected_norm == actual_norm:
        return "OK", ""
    if expected_norm in actual_norm or actual_norm in expected_norm:
        return "OK", ""
    return "MISMATCH", f"文件名={expected_norm}，OCR={actual_norm}"


def compare_id(expected: str, actual: str | None) -> tuple[str, str]:
    expected_norm = normalize_id_card(expected)
    actual_norm = normalize_id_card(actual)
    if not actual_norm:
        return "MISSING", "OCR 未识别到身份证号"
    if expected_norm == actual_norm:
        return "OK", ""
    return "MISMATCH", f"文件名={expected_norm}，OCR={actual_norm}"


def label_match(value: str) -> str:
    return MATCH_LABELS.get(value, value)


def label_overall(value: str) -> str:
    return OVERALL_LABELS.get(value, value)


def overall_status(name_match: str, id_match: str) -> str:
    if name_match == "OK" and id_match == "OK":
        return "OK"
    if name_match in {"MISSING", "MISMATCH"} and id_match in {"MISSING", "MISMATCH"}:
        return "BOTH_MISMATCH"
    if name_match != "OK":
        return "NAME_MISMATCH"
    return "ID_MISMATCH"


def iter_capture_files(captures_dir: Path) -> list[Path]:
    return sorted(captures_dir.rglob("*.png"))


def relative_subfolder(captures_dir: Path, file_path: Path) -> str:
    try:
        parent = file_path.parent.relative_to(captures_dir)
        return "" if str(parent) == "." else str(parent)
    except ValueError:
        return file_path.parent.name


def verify_file(engine: RapidOCR, captures_dir: Path, file_path: Path) -> VerifyResult:
    expected = parse_filename(file_path)
    subfolder = relative_subfolder(captures_dir, file_path)
    rel_file = str(file_path.relative_to(captures_dir.parent))

    if expected is None:
        return VerifyResult(
            file=rel_file,
            subfolder=subfolder,
            expected_name="",
            expected_id_card="",
            ocr_name="",
            ocr_id_card="",
            name_match="N/A",
            id_match="N/A",
            overall="BAD_FILENAME",
            ocr_confidence="",
            notes="文件名格式应为：姓名_身份证号.png",
        )

    ocr_info = ocr_image(engine, file_path)
    resolved_name = pick_best_name(ocr_info.name_candidates, expected.name) or ocr_info.name
    name_match, name_note = compare_name(expected.name, resolved_name)
    id_match, id_note = compare_id(expected.id_card, ocr_info.id_card)
    notes = "; ".join(part for part in [name_note, id_note] if part)

    return VerifyResult(
        file=rel_file,
        subfolder=subfolder,
        expected_name=expected.name,
        expected_id_card=expected.id_card,
        ocr_name=resolved_name or "",
        ocr_id_card=ocr_info.id_card or "",
        name_match=name_match,
        id_match=id_match,
        overall=overall_status(name_match, id_match),
        ocr_confidence=f"{ocr_info.confidence:.3f}",
        notes=notes,
    )


def result_to_report_row(row: VerifyResult) -> dict[str, str]:
    return {
        REPORT_COLUMNS["file"]: row.file,
        REPORT_COLUMNS["subfolder"]: row.subfolder,
        REPORT_COLUMNS["expected_name"]: row.expected_name,
        REPORT_COLUMNS["expected_id_card"]: row.expected_id_card,
        REPORT_COLUMNS["ocr_name"]: row.ocr_name,
        REPORT_COLUMNS["ocr_id_card"]: row.ocr_id_card,
        REPORT_COLUMNS["name_match"]: label_match(row.name_match),
        REPORT_COLUMNS["id_match"]: label_match(row.id_match),
        REPORT_COLUMNS["overall"]: label_overall(row.overall),
        REPORT_COLUMNS["ocr_confidence"]: row.ocr_confidence,
        REPORT_COLUMNS["notes"]: row.notes,
    }


class IncrementalReportWriter:
    def __init__(self, report_path: Path) -> None:
        self.report_path = report_path
        self.fieldnames = list(REPORT_COLUMNS.values())
        report_path.parent.mkdir(parents=True, exist_ok=True)
        self._handle = report_path.open("w", encoding="utf-8-sig", newline="")
        self._writer = csv.DictWriter(self._handle, fieldnames=self.fieldnames)
        self._writer.writeheader()
        self._handle.flush()

    def append(self, result: VerifyResult) -> None:
        self._writer.writerow(result_to_report_row(result))
        self._handle.flush()

    def close(self) -> None:
        self._handle.close()


def format_console_failure(result: VerifyResult) -> str:
    parts = [label_overall(result.overall)]
    if result.overall == "BAD_FILENAME":
        if result.notes:
            parts.append(result.notes)
        return " | ".join(parts)

    parts.append(
        f"文件名姓名={result.expected_name or '无'}，OCR姓名={result.ocr_name or '未识别'}"
    )
    parts.append(
        f"文件名身份证={result.expected_id_card or '无'}，OCR身份证={result.ocr_id_card or '未识别'}"
    )
    parts.append(f"姓名比对={label_match(result.name_match)}，身份证比对={label_match(result.id_match)}")
    if result.notes:
        parts.append(f"备注={result.notes}")
    return " | ".join(parts)


def print_result_line(index: int, total: int, file_path: Path, result: VerifyResult) -> None:
    prefix = f"[{index}/{total}] {file_path.name}"
    if result.overall == "OK":
        print(f"{prefix} OK")
        return
    print(f"{prefix} {format_console_failure(result)}")


def print_summary(rows: list[VerifyResult]) -> None:
    total = len(rows)
    ok = sum(1 for row in rows if row.overall == "OK")
    bad_name = sum(1 for row in rows if row.overall == "NAME_MISMATCH")
    bad_id = sum(1 for row in rows if row.overall == "ID_MISMATCH")
    both = sum(1 for row in rows if row.overall == "BOTH_MISMATCH")
    bad_filename = sum(1 for row in rows if row.overall == "BAD_FILENAME")

    print("")
    print("=== OCR 校验汇总 ===")
    print(f"总计: {total}")
    print(f"通过: {ok}")
    print(f"姓名不匹配: {bad_name}")
    print(f"身份证不匹配: {bad_id}")
    print(f"姓名和身份证均不匹配: {both}")
    print(f"文件名格式错误: {bad_filename}")

    problems = [row for row in rows if row.overall != "OK"]
    if problems:
        print("")
        print("前 20 条异常记录:")
        for row in problems[:20]:
            print(
                f"- {row.file}: {label_overall(row.overall)}，"
                f"文件名={row.expected_name}/{row.expected_id_card}，"
                f"OCR={row.ocr_name}/{row.ocr_id_card}"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify capture PNG names against OCR content.")
    parser.add_argument(
        "--captures-dir",
        default="captures",
        help="Directory containing capture PNG files (default: captures)",
    )
    parser.add_argument(
        "--report",
        default="logs/verify-report.csv",
        help="CSV report output path (default: logs/verify-report.csv)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Only verify the first N files (0 = all)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=0,
        help="Parallel worker processes (0/1 = serial, recommended; >1 to try multi-process)",
    )
    return parser


def make_engine(intra_threads: int) -> RapidOCR:
    # 截图均为正向，无需方向分类（use_cls），可省一次推理
    kwargs: dict = {"use_cls": False}
    if intra_threads and intra_threads > 0:
        kwargs["intra_op_num_threads"] = intra_threads
        kwargs["inter_op_num_threads"] = 1
    return RapidOCR(**kwargs)


_WORKER_ENGINE: RapidOCR | None = None
_WORKER_CAPTURES_DIR: Path | None = None


def _init_worker(captures_dir: str, intra_threads: int) -> None:
    global _WORKER_ENGINE, _WORKER_CAPTURES_DIR
    _WORKER_ENGINE = make_engine(intra_threads)
    _WORKER_CAPTURES_DIR = Path(captures_dir)


def _worker_verify(file_str: str) -> VerifyResult:
    assert _WORKER_ENGINE is not None and _WORKER_CAPTURES_DIR is not None
    return verify_file(_WORKER_ENGINE, _WORKER_CAPTURES_DIR, Path(file_str))


def resolve_worker_count(requested: int) -> int:
    # 默认串行：onnxruntime 单次推理已占满 CPU，多进程通常无并行收益甚至更慢。
    # 如需在其他机器尝试并发，可显式传 --workers N。
    if requested >= 1:
        return requested
    return 1


def threads_per_worker(workers: int) -> int:
    cpu = os.cpu_count() or 1
    return max(1, cpu // max(1, workers))


def main() -> int:
    args = build_parser().parse_args()
    project_root = Path(__file__).resolve().parent.parent
    captures_dir = (project_root / args.captures_dir).resolve()
    report_path = (project_root / args.report).resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)

    if not captures_dir.exists():
        print(f"Captures directory not found: {captures_dir}", file=sys.stderr)
        return 1

    files = iter_capture_files(captures_dir)
    if args.limit > 0:
        files = files[: args.limit]

    if not files:
        print(f"No PNG files found under: {captures_dir}")
        return 0

    workers = resolve_worker_count(args.workers)
    intra_threads = threads_per_worker(workers)
    total = len(files)
    print("Initializing RapidOCR (PP-OCR model)...")
    print(f"Verifying {total} file(s) from {captures_dir}")
    print(f"Report: {report_path} (append one row per image)")
    print(f"Workers: {workers} (intra-op threads/worker: {intra_threads})")

    rows: list[VerifyResult] = []
    writer = IncrementalReportWriter(report_path)
    try:
        if workers == 1:
            engine = make_engine(-1)
            for index, file_path in enumerate(files, start=1):
                result = verify_file(engine, captures_dir, file_path)
                rows.append(result)
                writer.append(result)
                print_result_line(index, total, file_path, result)
        else:
            file_strs = [str(f) for f in files]
            with ProcessPoolExecutor(
                max_workers=workers,
                initializer=_init_worker,
                initargs=(str(captures_dir), intra_threads),
            ) as executor:
                for index, result in enumerate(
                    executor.map(_worker_verify, file_strs, chunksize=4), start=1
                ):
                    rows.append(result)
                    writer.append(result)
                    print_result_line(index, total, Path(result.file), result)
    finally:
        writer.close()

    print_summary(rows)
    print(f"Report saved to: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
