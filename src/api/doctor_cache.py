from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from src.pipeline.io import load_json, save_json

DEFAULT_CACHE_TTL = timedelta(days=1)


def doctors_cache_path(workspace: Path) -> Path:
    return workspace / "doctors_api_cache.json"


def cache_fingerprint(api_cfg: dict[str, Any]) -> str:
    return f"{api_cfg.get('baseUrl')}|{api_cfg.get('pageSize')}"


def _parse_fetched_at(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed
    except (TypeError, ValueError):
        return None


def read_doctors_cache(
    cache_path: Path,
    *,
    ttl: timedelta = DEFAULT_CACHE_TTL,
    fingerprint: str,
) -> list[dict[str, Any]] | None:
    if not cache_path.exists():
        return None

    try:
        payload = load_json(cache_path)
    except (OSError, ValueError):
        return None

    if not isinstance(payload, dict):
        return None
    if payload.get("fingerprint") != fingerprint:
        return None

    fetched_at = _parse_fetched_at(str(payload.get("fetchedAt") or ""))
    if fetched_at is None:
        return None
    if datetime.now(timezone.utc) - fetched_at > ttl:
        return None

    records = payload.get("records")
    if not isinstance(records, list):
        return None
    return records


def write_doctors_cache(
    cache_path: Path,
    records: list[dict[str, Any]],
    *,
    fingerprint: str,
) -> None:
    save_json(
        cache_path,
        {
            "fetchedAt": datetime.now(timezone.utc).isoformat(),
            "fingerprint": fingerprint,
            "count": len(records),
            "records": records,
        },
    )


def fetch_doctors_with_cache(
    api_cfg: dict[str, Any],
    workspace: Path,
    *,
    refresh: bool = False,
    max_pages: int | None = None,
    ttl: timedelta = DEFAULT_CACHE_TTL,
) -> list[dict[str, Any]]:
    from .doctor_medical import fetch_all_records

    if max_pages is not None:
        return fetch_all_records(api_cfg, max_pages=max_pages)

    workspace.mkdir(parents=True, exist_ok=True)
    cache_path = doctors_cache_path(workspace)
    fingerprint = cache_fingerprint(api_cfg)

    if not refresh:
        cached = read_doctors_cache(cache_path, ttl=ttl, fingerprint=fingerprint)
        if cached is not None:
            try:
                payload = load_json(cache_path)
                fetched_at = str(payload.get("fetchedAt") or "")
            except (OSError, ValueError):
                fetched_at = ""
            print(
                f"using cached doctors: {len(cached)} records"
                + (f" (fetched at {fetched_at})" if fetched_at else "")
            )
            print(f"cache: {cache_path}  (pass --refresh-cache to refetch)")
            return cached

    records = fetch_all_records(api_cfg, max_pages=None)
    write_doctors_cache(cache_path, records, fingerprint=fingerprint)
    print(f"cached {len(records)} doctors to {cache_path}")
    return records
