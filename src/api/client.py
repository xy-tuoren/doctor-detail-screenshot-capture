from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any

from .constants import API_PATH


def build_url(api_cfg: dict[str, Any]) -> str:
    base = str(api_cfg["baseUrl"]).rstrip("/")
    query = (
        f"nonce={api_cfg['nonce']}"
        f"&timestamp={api_cfg['timestamp']}"
        f"&sign={api_cfg['sign']}"
    )
    return f"{base}{API_PATH}?{query}"


def request_page(
    api_cfg: dict[str, Any],
    page_index: int,
    page_size: int,
) -> dict[str, Any]:
    url = build_url(api_cfg)
    body = json.dumps({"pageSize": page_size, "pageIndex": page_index}).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "sign": str(api_cfg.get("headerSign", "lo")),
    }
    timeout = int(api_cfg.get("requestTimeoutSeconds", 60))
    retries = int(api_cfg.get("retryCount", 3))
    delay = float(api_cfg.get("retryDelaySeconds", 2))

    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            if payload.get("code") != 1:
                raise RuntimeError(
                    f"API error on page {page_index}: code={payload.get('code')} msg={payload.get('msg')}"
                )
            data = payload.get("data")
            if not isinstance(data, dict):
                raise RuntimeError(f"API page {page_index} returned invalid data")
            return data
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as exc:
            last_error = exc
            if attempt >= retries:
                break
            print(
                f"  page {page_index} attempt {attempt}/{retries} failed: {exc}; retrying...",
                file=sys.stderr,
            )
            time.sleep(delay)

    assert last_error is not None
    raise last_error
