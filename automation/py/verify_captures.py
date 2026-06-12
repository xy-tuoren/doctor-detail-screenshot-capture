#!/usr/bin/env python3
"""Verify capture PNG filenames against OCR-extracted ID card numbers."""

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
ID_LABEL_PATTERN = re.compile(
    r"身份证(?:号码|号|證)?[:：]?\s*([0-9A-Za-z|!]{14,25})"
)
FILENAME_PATTERN = re.compile(r"^(.+)_(.{15,18})$")

OCR_CHAR_MAP = {
    "O": "0",
    "Q": "0",
    "D": "0",
    "I": "1",
    "L": "1",
    "|": "1",
    "!": "1",
    "Z": "2",
    "A": "4",
    "S": "5",
    "G": "6",
    "T": "7",
    "B": "8",
    "X": "X",
}

REPORT_COLUMNS = {
    "file": "文件路径",
    "subfolder": "子目录",
    "expected_name": "文件名姓名",
    "expected_id_card": "文件名身份证",
    "ocr_id_card": "OCR识别身份证",
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
    "ID_MISMATCH": "身份证不匹配",
    "BAD_FILENAME": "文件名格式错误",
}

REVERSE_MATCH_LABELS = {label: code for code, label in MATCH_LABELS.items()}
REVERSE_OVERALL_LABELS = {label: code for code, label in OVERALL_LABELS.items()}


@dataclass
class ExpectedInfo:
    name: str
    id_card: str


@dataclass
class OcrInfo:
    id_card: str | None
    text: str
    confidence: float


@dataclass
class VerifyResult:
    file: str
    subfolder: str
    expected_name: str
    expected_id_card: str
    ocr_id_card: str
    id_match: str
    overall: str
    ocr_confidence: str
    notes: str


def normalize_id_card(value: str | None) -> str:
    if not value:
        return ""
    return value.strip().upper().replace(" ", "")


def convert_ocr_token_to_id_card(token: str | None) -> str | None:
    if not token:
        return None

    cleaned_chars: list[str] = []
    for ch in token.upper():
        if ch.isdigit():
            cleaned_chars.append(ch)
        elif ch in OCR_CHAR_MAP:
            cleaned_chars.append(OCR_CHAR_MAP[ch])

    cleaned = "".join(cleaned_chars)
    if len(cleaned) == 18 and re.fullmatch(r"\d{17}[\dX]", cleaned):
        return cleaned
    if len(cleaned) == 15 and re.fullmatch(r"\d{15}", cleaned):
        return cleaned
    if len(cleaned) > 18:
        match = re.match(r"\d{17}[\dX]", cleaned)
        if match:
            return match.group(0)
        match = re.match(r"\d{15}", cleaned)
        if match:
            return match.group(0)
    return None


def extract_id_from_text(text: str) -> str | None:
    if not text:
        return None

    compact = re.sub(r"\s+", "", text)
    label_match = ID_LABEL_PATTERN.search(compact)
    if label_match:
        normalized = convert_ocr_token_to_id_card(label_match.group(1))
        if normalized:
            return normalized

    for source in (compact, text):
        matches = ID_CARD_PATTERN.findall(source)
        if matches:
            eighteen = [m for m in matches if len(m) == 18]
            chosen = eighteen[0] if eighteen else matches[0]
            return normalize_id_card(chosen)
    return None


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
    """基本信息整块：通常同时包含身份证号。"""
    height, width = image.shape[:2]
    return image[int(height * 0.06) : int(height * 0.44), 0 : int(width * 0.78)]


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


def ocr_image(engine: RapidOCR, path: Path) -> OcrInfo:
    image = load_image(path)

    base_text, base_conf = run_ocr(engine, maybe_upscale(crop_basic_info_region(image)))
    texts = [base_text] if base_text else []
    confidences = [base_conf] if base_conf > 0 else []

    best_id = extract_id_from_text(base_text)

    if not best_id:
        id_text, id_conf = run_ocr(engine, maybe_upscale(crop_id_card_region(image)))
        if id_text:
            texts.append(id_text)
            if id_conf > 0:
                confidences.append(id_conf)
            best_id = extract_id_from_text(id_text)

    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0
    full_text = "\n".join(texts)

    return OcrInfo(
        id_card=best_id,
        text=full_text,
        confidence=avg_conf,
    )


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


def overall_status(id_match: str) -> str:
    if id_match == "OK":
        return "OK"
    return "ID_MISMATCH"


def iter_capture_files(captures_dir: Path) -> list[Path]:
    return sorted(captures_dir.rglob("*.png"))


def make_rel_file(captures_dir: Path, file_path: Path) -> str:
    return str(file_path.relative_to(captures_dir.parent)).replace("\\", "/")


def row_dict_to_result(row: dict[str, str]) -> VerifyResult:
    id_match = REVERSE_MATCH_LABELS.get(row.get(REPORT_COLUMNS["id_match"], ""), "N/A")
    overall = REVERSE_OVERALL_LABELS.get(row.get(REPORT_COLUMNS["overall"], ""), "ID_MISMATCH")
    return VerifyResult(
        file=row.get(REPORT_COLUMNS["file"], "").replace("\\", "/"),
        subfolder=row.get(REPORT_COLUMNS["subfolder"], ""),
        expected_name=row.get(REPORT_COLUMNS["expected_name"], ""),
        expected_id_card=row.get(REPORT_COLUMNS["expected_id_card"], ""),
        ocr_id_card=row.get(REPORT_COLUMNS["ocr_id_card"], ""),
        id_match=id_match,
        overall=overall,
        ocr_confidence=row.get(REPORT_COLUMNS["ocr_confidence"], ""),
        notes=row.get(REPORT_COLUMNS["notes"], ""),
    )


def load_existing_report(report_path: Path) -> dict[str, VerifyResult]:
    if not report_path.exists():
        return {}

    existing: dict[str, VerifyResult] = {}
    with report_path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            result = row_dict_to_result(row)
            if result.file:
                existing[result.file] = result
    return existing


def select_files_to_verify(
    all_files: list[Path],
    captures_dir: Path,
    existing: dict[str, VerifyResult],
    *,
    force: bool,
) -> tuple[list[Path], int]:
    if force:
        return all_files, 0

    passed_keys = {key for key, row in existing.items() if row.overall == "OK"}
    to_verify = [
        file_path
        for file_path in all_files
        if make_rel_file(captures_dir, file_path) not in passed_keys
    ]
    skipped = len(all_files) - len(to_verify)
    return to_verify, skipped


def relative_subfolder(captures_dir: Path, file_path: Path) -> str:
    try:
        parent = file_path.parent.relative_to(captures_dir)
        return "" if str(parent) == "." else str(parent)
    except ValueError:
        return file_path.parent.name


def verify_file(engine: RapidOCR, captures_dir: Path, file_path: Path) -> VerifyResult:
    expected = parse_filename(file_path)
    subfolder = relative_subfolder(captures_dir, file_path)
    rel_file = make_rel_file(captures_dir, file_path)

    if expected is None:
        return VerifyResult(
            file=rel_file,
            subfolder=subfolder,
            expected_name="",
            expected_id_card="",
            ocr_id_card="",
            id_match="N/A",
            overall="BAD_FILENAME",
            ocr_confidence="",
            notes="文件名格式应为：姓名_身份证号.png",
        )

    ocr_info = ocr_image(engine, file_path)
    id_match, id_note = compare_id(expected.id_card, ocr_info.id_card)

    return VerifyResult(
        file=rel_file,
        subfolder=subfolder,
        expected_name=expected.name,
        expected_id_card=expected.id_card,
        ocr_id_card=ocr_info.id_card or "",
        id_match=id_match,
        overall=overall_status(id_match),
        ocr_confidence=f"{ocr_info.confidence:.3f}",
        notes=id_note,
    )


def result_to_report_row(row: VerifyResult) -> dict[str, str]:
    return {
        REPORT_COLUMNS["file"]: row.file,
        REPORT_COLUMNS["subfolder"]: row.subfolder,
        REPORT_COLUMNS["expected_name"]: row.expected_name,
        REPORT_COLUMNS["expected_id_card"]: row.expected_id_card,
        REPORT_COLUMNS["ocr_id_card"]: row.ocr_id_card,
        REPORT_COLUMNS["id_match"]: label_match(row.id_match),
        REPORT_COLUMNS["overall"]: label_overall(row.overall),
        REPORT_COLUMNS["ocr_confidence"]: row.ocr_confidence,
        REPORT_COLUMNS["notes"]: row.notes,
    }


class IncrementalReportWriter:
    def __init__(
        self,
        report_path: Path,
        existing_ok_rows: list[VerifyResult] | None = None,
    ) -> None:
        self.report_path = report_path
        self.fieldnames = list(REPORT_COLUMNS.values())
        self._problem_rows: list[VerifyResult] = []
        self._ok_rows: list[VerifyResult] = list(existing_ok_rows or [])
        report_path.parent.mkdir(parents=True, exist_ok=True)
        self._rewrite()

    def append(self, result: VerifyResult) -> None:
        self._ok_rows = [row for row in self._ok_rows if row.file != result.file]
        self._problem_rows = [row for row in self._problem_rows if row.file != result.file]
        if result.overall == "OK":
            self._ok_rows.append(result)
        else:
            # 每发现一条异常，立即插到报告最上方（表头之下）。
            self._problem_rows.insert(0, result)
        self._rewrite()

    def all_rows(self) -> list[VerifyResult]:
        return [*self._problem_rows, *self._ok_rows]

    def _rewrite(self) -> None:
        with self.report_path.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=self.fieldnames)
            writer.writeheader()
            for row in self._problem_rows:
                writer.writerow(result_to_report_row(row))
            for row in self._ok_rows:
                writer.writerow(result_to_report_row(row))

    def close(self) -> None:
        self._rewrite()


def format_console_failure(result: VerifyResult) -> str:
    parts = [label_overall(result.overall)]
    if result.overall == "BAD_FILENAME":
        if result.notes:
            parts.append(result.notes)
        return " | ".join(parts)

    parts.append(
        f"文件名身份证={result.expected_id_card or '无'}，OCR身份证={result.ocr_id_card or '未识别'}"
    )
    parts.append(f"身份证比对={label_match(result.id_match)}")
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
    bad_id = sum(1 for row in rows if row.overall == "ID_MISMATCH")
    bad_filename = sum(1 for row in rows if row.overall == "BAD_FILENAME")

    print("")
    print("=== OCR 校验汇总 ===")
    print(f"总计: {total}")
    print(f"通过: {ok}")
    print(f"身份证不匹配: {bad_id}")
    print(f"文件名格式错误: {bad_filename}")

    problems = [row for row in rows if row.overall != "OK"]
    if problems:
        print("")
        print("前 20 条异常记录:")
        for row in problems[:20]:
            print(
                f"- {row.file}: {label_overall(row.overall)}，"
                f"文件名身份证={row.expected_id_card}，"
                f"OCR身份证={row.ocr_id_card or '未识别'}"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify capture PNG filenames against OCR-extracted ID card numbers."
    )
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
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-verify all files, ignoring previously passed records in the report",
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
    project_root = Path(__file__).resolve().parent.parent.parent
    captures_dir = (project_root / args.captures_dir).resolve()
    report_path = (project_root / args.report).resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)

    if not captures_dir.exists():
        print(f"Captures directory not found: {captures_dir}", file=sys.stderr)
        return 1

    all_files = iter_capture_files(captures_dir)
    if not all_files:
        print(f"No PNG files found under: {captures_dir}")
        return 0

    existing = load_existing_report(report_path)
    current_keys = {make_rel_file(captures_dir, file_path) for file_path in all_files}
    existing = {key: row for key, row in existing.items() if key in current_keys}

    files, skipped = select_files_to_verify(
        all_files,
        captures_dir,
        existing,
        force=args.force,
    )
    if args.limit > 0:
        files = files[: args.limit]

    existing_ok_rows = [] if args.force else [row for row in existing.values() if row.overall == "OK"]
    existing_problems = [] if args.force else [row for row in existing.values() if row.overall != "OK"]
    verify_keys = {make_rel_file(captures_dir, file_path) for file_path in files}
    preserved_problems = [row for row in existing_problems if row.file not in verify_keys]

    workers = resolve_worker_count(args.workers)
    intra_threads = threads_per_worker(workers)
    total = len(files)
    print("Initializing RapidOCR (PP-OCR model)...")
    print(f"PNG files under {captures_dir}: {len(all_files)}")
    if args.force:
        print("Mode: force re-verify all files")
    elif skipped:
        print(f"Skipping {skipped} previously passed file(s) from {report_path.name}")
    print(f"Verifying {total} file(s)")
    print(f"Report: {report_path} (异常实时插入最上方)")
    print(f"Workers: {workers} (intra-op threads/worker: {intra_threads})")

    if total == 0:
        writer = IncrementalReportWriter(report_path, existing_ok_rows=existing_ok_rows)
        for row in preserved_problems:
            writer.append(row)
        writer.close()
        print("No new files to verify.")
        print_summary(writer.all_rows())
        print(f"Report saved to: {report_path}")
        return 0

    rows: list[VerifyResult] = []
    writer = IncrementalReportWriter(report_path, existing_ok_rows=existing_ok_rows)
    for row in preserved_problems:
        writer.append(row)
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

    print_summary(writer.all_rows())
    print(f"Report saved to: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
