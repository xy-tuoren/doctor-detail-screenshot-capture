"""OCR-verify NHC capture filenames against screenshot content (姓名 + 执业证书编码)."""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path

from rapidocr_onnxruntime import RapidOCR

from src.capture.cert_ocr import (
    _load_image,
    _maybe_upscale,
    _run_ocr,
    extract_cert_from_text,
    make_ocr_engine,
    normalize_cert_code,
)
from src.capture.nhc_core import cert_codes_match
from src.capture.paths import default_nhc_captures_dir
from src.reconcile.matcher import normalize_name

FILENAME_PATTERN = re.compile(r"^(.+)_([0-9A-Za-z]{10,30})$")
NAME_LABEL_PATTERN = re.compile(
    r"姓名[:：]?\s*([\u4e00-\u9fa5·A-Za-z]{2,20}?)(?=性别[:：]|医师级别|执业类别|$)"
)

REPORT_COLUMNS = {
    "file": "文件路径",
    "expected_name": "文件名姓名",
    "expected_cert_code": "文件名执业证书编号",
    "ocr_name": "OCR识别姓名",
    "ocr_cert_code": "OCR识别执业证书编号",
    "name_match": "姓名比对",
    "cert_match": "执业证书编号比对",
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
    "CERT_MISMATCH": "执业证书编号不匹配",
    "NAME_MISMATCH": "姓名不匹配",
    "BOTH_MISMATCH": "姓名与执业证书编号均不匹配",
    "BAD_FILENAME": "文件名格式错误",
}

REVERSE_MATCH_LABELS = {label: code for code, label in MATCH_LABELS.items()}
REVERSE_OVERALL_LABELS = {label: code for code, label in OVERALL_LABELS.items()}


@dataclass
class ExpectedInfo:
    name: str
    cert_code: str


@dataclass
class OcrFields:
    name: str | None
    cert_code: str | None
    text: str
    confidence: float


@dataclass
class VerifyResult:
    file: str
    expected_name: str
    expected_cert_code: str
    ocr_name: str
    ocr_cert_code: str
    name_match: str
    cert_match: str
    overall: str
    ocr_confidence: str
    notes: str


def parse_nhc_filename(path: Path) -> ExpectedInfo | None:
    match = FILENAME_PATTERN.match(path.stem)
    if not match:
        return None
    return ExpectedInfo(
        name=normalize_name(match.group(1)),
        cert_code=normalize_cert_code(match.group(2)),
    )


def extract_name_from_text(text: str) -> str | None:
    if not text:
        return None
    compact = re.sub(r"\s+", "", text)
    match = NAME_LABEL_PATTERN.search(compact)
    if match:
        return normalize_name(match.group(1))
    return None


def name_in_text(expected: str, text: str) -> bool:
    if not expected or not text:
        return False
    compact = re.sub(r"\s+", "", text)
    return expected in compact or expected.replace("·", "") in compact.replace("·", "")


def compare_name(expected: str, actual: str | None, full_text: str) -> tuple[str, str]:
    expected_norm = normalize_name(expected)
    actual_norm = normalize_name(actual)
    if actual_norm and actual_norm == expected_norm:
        return "OK", ""
    if name_in_text(expected_norm, full_text):
        return "OK", ""
    if not actual_norm and not name_in_text(expected_norm, full_text):
        return "MISSING", "OCR 未识别到姓名"
    return "MISMATCH", f"文件名={expected_norm}，OCR={actual_norm or '未识别'}"


def compare_cert(expected: str, actual: str | None) -> tuple[str, str]:
    if not actual:
        return "MISSING", "OCR 未识别到执业证书编号"
    if cert_codes_match(actual, expected):
        return "OK", ""
    return (
        "MISMATCH",
        f"文件名={normalize_cert_code(expected)}，OCR={normalize_cert_code(actual)}",
    )


def ocr_nhc_fields(engine: RapidOCR, path: Path) -> OcrFields:
    image = _load_image(path)
    text, confidence = _run_ocr(engine, _maybe_upscale(image))
    return OcrFields(
        name=extract_name_from_text(text),
        cert_code=extract_cert_from_text(text),
        text=text,
        confidence=confidence,
    )


def overall_status(name_match: str, cert_match: str) -> str:
    if name_match == "OK" and cert_match == "OK":
        return "OK"
    if name_match != "OK" and cert_match != "OK":
        return "BOTH_MISMATCH"
    if cert_match != "OK":
        return "CERT_MISMATCH"
    return "NAME_MISMATCH"


def label_match(value: str) -> str:
    return MATCH_LABELS.get(value, value)


def label_overall(value: str) -> str:
    return OVERALL_LABELS.get(value, value)


def verify_nhc_file(
    engine: RapidOCR,
    *,
    captures_dir: Path,
    file_path: Path,
) -> VerifyResult:
    expected = parse_nhc_filename(file_path)
    rel_file = str(file_path.relative_to(captures_dir)).replace("\\", "/")

    if expected is None:
        return VerifyResult(
            file=rel_file,
            expected_name="",
            expected_cert_code="",
            ocr_name="",
            ocr_cert_code="",
            name_match="N/A",
            cert_match="N/A",
            overall="BAD_FILENAME",
            ocr_confidence="",
            notes="文件名格式应为：姓名_执业证书编号.png",
        )

    ocr_info = ocr_nhc_fields(engine, file_path)
    name_match, name_note = compare_name(expected.name, ocr_info.name, ocr_info.text)
    cert_match, cert_note = compare_cert(expected.cert_code, ocr_info.cert_code)

    notes = "；".join(part for part in (name_note, cert_note) if part)

    return VerifyResult(
        file=rel_file,
        expected_name=expected.name,
        expected_cert_code=expected.cert_code,
        ocr_name=ocr_info.name or "",
        ocr_cert_code=ocr_info.cert_code or "",
        name_match=name_match,
        cert_match=cert_match,
        overall=overall_status(name_match, cert_match),
        ocr_confidence=f"{ocr_info.confidence:.3f}",
        notes=notes,
    )


def result_to_report_row(row: VerifyResult) -> dict[str, str]:
    return {
        REPORT_COLUMNS["file"]: row.file,
        REPORT_COLUMNS["expected_name"]: row.expected_name,
        REPORT_COLUMNS["expected_cert_code"]: row.expected_cert_code,
        REPORT_COLUMNS["ocr_name"]: row.ocr_name,
        REPORT_COLUMNS["ocr_cert_code"]: row.ocr_cert_code,
        REPORT_COLUMNS["name_match"]: label_match(row.name_match),
        REPORT_COLUMNS["cert_match"]: label_match(row.cert_match),
        REPORT_COLUMNS["overall"]: label_overall(row.overall),
        REPORT_COLUMNS["ocr_confidence"]: row.ocr_confidence,
        REPORT_COLUMNS["notes"]: row.notes,
    }


def row_dict_to_result(row: dict[str, str]) -> VerifyResult:
    return VerifyResult(
        file=row.get(REPORT_COLUMNS["file"], "").replace("\\", "/"),
        expected_name=row.get(REPORT_COLUMNS["expected_name"], ""),
        expected_cert_code=row.get(REPORT_COLUMNS["expected_cert_code"], ""),
        ocr_name=row.get(REPORT_COLUMNS["ocr_name"], ""),
        ocr_cert_code=row.get(REPORT_COLUMNS["ocr_cert_code"], ""),
        name_match=REVERSE_MATCH_LABELS.get(row.get(REPORT_COLUMNS["name_match"], ""), "N/A"),
        cert_match=REVERSE_MATCH_LABELS.get(row.get(REPORT_COLUMNS["cert_match"], ""), "N/A"),
        overall=REVERSE_OVERALL_LABELS.get(
            row.get(REPORT_COLUMNS["overall"], ""), "BOTH_MISMATCH"
        ),
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


class IncrementalReportWriter:
    def __init__(
        self,
        report_path: Path,
        existing_ok_rows: list[VerifyResult] | None = None,
        *,
        flush_every: int = 25,
    ) -> None:
        self.report_path = report_path
        self.fieldnames = list(REPORT_COLUMNS.values())
        self._problem_rows: list[VerifyResult] = []
        self._ok_rows: list[VerifyResult] = list(existing_ok_rows or [])
        self._flush_every = max(1, flush_every)
        self._pending_writes = 0
        report_path.parent.mkdir(parents=True, exist_ok=True)
        self._rewrite()

    def append(self, result: VerifyResult) -> None:
        self._ok_rows = [row for row in self._ok_rows if row.file != result.file]
        self._problem_rows = [row for row in self._problem_rows if row.file != result.file]
        if result.overall == "OK":
            self._ok_rows.append(result)
        else:
            self._problem_rows.insert(0, result)
        self._pending_writes += 1
        if self._pending_writes >= self._flush_every:
            self._rewrite()
            self._pending_writes = 0

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
        f"文件名={result.expected_name}/{result.expected_cert_code}，"
        f"OCR={result.ocr_name or '未识别'}/{result.ocr_cert_code or '未识别'}"
    )
    parts.append(f"姓名={label_match(result.name_match)}，证号={label_match(result.cert_match)}")
    if result.notes:
        parts.append(f"备注={result.notes}")
    return " | ".join(parts)


def print_summary(rows: list[VerifyResult]) -> None:
    total = len(rows)
    ok = sum(1 for row in rows if row.overall == "OK")
    bad_cert = sum(1 for row in rows if row.overall == "CERT_MISMATCH")
    bad_name = sum(1 for row in rows if row.overall == "NAME_MISMATCH")
    both = sum(1 for row in rows if row.overall == "BOTH_MISMATCH")
    bad_filename = sum(1 for row in rows if row.overall == "BAD_FILENAME")

    print("")
    print("=== 卫健委 OCR 校验汇总 ===")
    print(f"总计: {total}")
    print(f"通过: {ok}")
    print(f"执业证书编号不匹配: {bad_cert}")
    print(f"姓名不匹配: {bad_name}")
    print(f"姓名与执业证书编号均不匹配: {both}")
    print(f"文件名格式错误: {bad_filename}")

    problems = [row for row in rows if row.overall != "OK"]
    if problems:
        print("")
        print("前 20 条异常记录:")
        for row in problems[:20]:
            print(f"- {row.file}: {label_overall(row.overall)} | {row.notes or format_console_failure(row)}")


@dataclass
class VerifyNhcSummary:
    total: int
    ok: int
    cert_mismatch: int
    name_mismatch: int
    both_mismatch: int
    bad_filename: int
    report_path: Path


def verify_nhc_captures(
    *,
    captures_dir: Path | None = None,
    report_path: Path | None = None,
    limit: int = 0,
    force: bool = False,
    verbose: bool = True,
) -> VerifyNhcSummary:
    from src.api.config import project_root

    root = project_root()
    nhc_dir = captures_dir or default_nhc_captures_dir(root)
    report = report_path or (root / "logs" / "verify-nhc-report.csv")
    report.parent.mkdir(parents=True, exist_ok=True)

    if not nhc_dir.exists():
        raise FileNotFoundError(f"NHC captures directory not found: {nhc_dir}")

    all_files = sorted(nhc_dir.glob("*.png"))
    if not all_files:
        print(f"No PNG files found under: {nhc_dir}")
        return VerifyNhcSummary(0, 0, 0, 0, 0, 0, report)

    existing = load_existing_report(report)
    current_keys = {path.name for path in all_files}
    existing = {key: row for key, row in existing.items() if key in current_keys}

    if force:
        files = all_files
        skipped = 0
        existing_ok_rows: list[VerifyResult] = []
        preserved_problems: list[VerifyResult] = []
    else:
        passed_keys = {key for key, row in existing.items() if row.overall == "OK"}
        files = [path for path in all_files if path.name not in passed_keys]
        skipped = len(all_files) - len(files)
        existing_ok_rows = [row for row in existing.values() if row.overall == "OK"]
        verify_keys = {path.name for path in files}
        preserved_problems = [
            row for row in existing.values() if row.overall != "OK" and row.file not in verify_keys
        ]

    if limit > 0:
        files = files[:limit]

    total = len(files)
    if verbose:
        print("Initializing RapidOCR (PP-OCR model)...")
        print(f"PNG files under {nhc_dir}: {len(all_files)}")
        if force:
            print("Mode: force re-verify all files")
        elif skipped:
            print(f"Skipping {skipped} previously passed file(s) from {report.name}")
        print(f"Verifying {total} file(s)")
        print(f"Report: {report} (异常实时插入最上方)")

    if total == 0:
        writer = IncrementalReportWriter(report, existing_ok_rows=existing_ok_rows)
        for row in preserved_problems:
            writer.append(row)
        writer.close()
        rows = writer.all_rows()
        if verbose:
            print("No new files to verify.")
            print_summary(rows)
            print(f"Report saved to: {report}")
        return VerifyNhcSummary(
            total=len(rows),
            ok=sum(1 for row in rows if row.overall == "OK"),
            cert_mismatch=sum(1 for row in rows if row.overall == "CERT_MISMATCH"),
            name_mismatch=sum(1 for row in rows if row.overall == "NAME_MISMATCH"),
            both_mismatch=sum(1 for row in rows if row.overall == "BOTH_MISMATCH"),
            bad_filename=sum(1 for row in rows if row.overall == "BAD_FILENAME"),
            report_path=report,
        )

    engine = make_ocr_engine()
    writer = IncrementalReportWriter(report, existing_ok_rows=existing_ok_rows)
    for row in preserved_problems:
        writer.append(row)

    try:
        for index, file_path in enumerate(files, start=1):
            result = verify_nhc_file(engine, captures_dir=nhc_dir, file_path=file_path)
            writer.append(result)
            if verbose and (result.overall != "OK" or index == total or index % 50 == 0):
                prefix = f"[{index}/{total}] {file_path.name}"
                if result.overall == "OK":
                    print(f"{prefix} OK")
                else:
                    print(f"{prefix} {format_console_failure(result)}")
    finally:
        writer.close()

    rows = writer.all_rows()
    if verbose:
        print_summary(rows)
        print(f"Report saved to: {report}")

    return VerifyNhcSummary(
        total=len(rows),
        ok=sum(1 for row in rows if row.overall == "OK"),
        cert_mismatch=sum(1 for row in rows if row.overall == "CERT_MISMATCH"),
        name_mismatch=sum(1 for row in rows if row.overall == "NAME_MISMATCH"),
        both_mismatch=sum(1 for row in rows if row.overall == "BOTH_MISMATCH"),
        bad_filename=sum(1 for row in rows if row.overall == "BAD_FILENAME"),
        report_path=report,
    )
