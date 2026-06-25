"""Normalize NHC screenshot filenames to 姓名_执业证书编号.png."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from src.capture.paths import default_nhc_captures_dir
from src.capture.rename_by_export import load_all_export_cert_lookup
from src.reconcile.matcher import normalize_id_card, normalize_name

_NAME_LEADING = re.compile(r"^([\u4e00-\u9fa5·A-Za-z]{2,20})")
_CJK_RUN = re.compile(r"[\u4e00-\u9fa5·]{2,20}")
_CERT_SUFFIX = re.compile(r"(\d{15})$")
_CERT_SUFFIX_LOOSE = re.compile(r"(\d{10,17})$")


@dataclass
class NhcRenameResult:
    renamed: int = 0
    skipped_already: int = 0
    skipped_unparsed: int = 0
    conflicts: int = 0
    errors: list[str] | None = None

    def __post_init__(self) -> None:
        if self.errors is None:
            self.errors = []


def extract_cert_from_stem(stem: str) -> str | None:
    cert_match = _CERT_SUFFIX.search(stem)
    if not cert_match:
        cert_match = _CERT_SUFFIX_LOOSE.search(stem)
    return cert_match.group(1) if cert_match else None


def _name_from_stem(stem: str, cert: str) -> str | None:
    """从乱码/拼接文件名中尽量提取姓名（导出表不可用时的兜底）。"""
    name_match = _NAME_LEADING.match(stem)
    if name_match:
        name = normalize_name(name_match.group(1).rstrip("_"))
        if name:
            return name
    prefix = stem[: stem.rfind(cert)].rstrip("_-·. ")
    runs = _CJK_RUN.findall(prefix)
    if runs:
        return normalize_name(max(runs, key=len).rstrip("_"))
    return None


def resolve_nhc_name_and_cert(
    stem: str,
    cert_lookup: dict[str, dict[str, str]] | None = None,
) -> tuple[str, str] | None:
    """执业证号优先取自文件名末尾；姓名优先取自机构导出表。"""
    cert = extract_cert_from_stem(stem)
    if not cert:
        return None
    norm_cert = normalize_id_card(cert)
    if cert_lookup:
        row = cert_lookup.get(norm_cert) or cert_lookup.get(cert)
        if row and row.get("name"):
            return normalize_name(row["name"]), cert
    name = _name_from_stem(stem, cert)
    if not name:
        return None
    return name, cert


def parse_nhc_filename(stem: str) -> tuple[str, str] | None:
    """从文件名解析姓名与执业证书编号（兼容旧调用，不含导出表）。"""
    return resolve_nhc_name_and_cert(stem, cert_lookup=None)


def _target_name(name: str, cert: str) -> str:
    return f"{name}_{cert}.png"


def rename_nhc_screenshots(
    *,
    source_dir: Path,
    target_dir: Path | None = None,
    exports_root: Path | None = None,
    cert_lookup: dict[str, dict[str, str]] | None = None,
    dry_run: bool = True,
    delete_source: bool = False,
) -> NhcRenameResult:
    """将 captures/screenshots 等目录下的卫健委图规范命名并移到 target_dir。"""
    out_dir = target_dir or default_nhc_captures_dir(source_dir.parent.parent)
    result = NhcRenameResult()

    if not source_dir.is_dir():
        result.errors.append(f"source not found: {source_dir}")
        return result

    lookup = cert_lookup
    if lookup is None and exports_root is not None:
        lookup = load_all_export_cert_lookup(exports_root)

    out_dir.mkdir(parents=True, exist_ok=True)

    for path in sorted(source_dir.glob("*.png")):
        parsed = resolve_nhc_name_and_cert(path.stem, cert_lookup=lookup)
        if parsed is None:
            result.skipped_unparsed += 1
            result.errors.append(f"unparsed: {path.name}")
            continue

        name, cert = parsed
        target = out_dir / _target_name(name, cert)

        if path.resolve() == target.resolve():
            result.skipped_already += 1
            continue

        if target.exists():
            # 源目录已有正确命名副本时，仅删除重复源文件
            if delete_source and path.parent.resolve() != out_dir.resolve():
                if dry_run:
                    print(f"[DRY DELETE dup] {path.name} (target exists: {target.name})")
                else:
                    path.unlink()
                    print(f"[DELETE dup] {path.name} (target exists: {target.name})")
                result.skipped_already += 1
                continue
            result.conflicts += 1
            result.errors.append(f"target exists: {target.name} (from {path.name})")
            continue

        if dry_run:
            rel = target.relative_to(out_dir.parent.parent) if out_dir.parent.parent in target.parents else target
            try:
                print(f"[DRY] {path.name} -> {rel}")
            except UnicodeEncodeError:
                print(f"[DRY] -> {target.name}")
        else:
            if delete_source or path.parent.resolve() == out_dir.resolve():
                path.rename(target)
            else:
                path.replace(target)
            try:
                print(f"[OK] {path.name} -> {target.name}")
            except UnicodeEncodeError:
                print(f"[OK] -> {target.name}")
        result.renamed += 1

    return result
