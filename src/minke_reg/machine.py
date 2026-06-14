from __future__ import annotations

import hashlib
import platform
import subprocess
import uuid


def _run_wmic(args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["wmic"] + args,
            capture_output=True,
            text=True,
            timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        lines = [ln.strip() for ln in result.stdout.splitlines() if ln.strip()]
        if len(lines) >= 2:
            return lines[1]
    except Exception:
        pass
    return ""


def build_machine_fingerprint() -> tuple[str, str]:
    """Return (S2, S3) machine identifiers used by the desktop client login."""
    if platform.system() != "Windows":
        node = platform.node() or "unknown"
        digest = hashlib.md5(node.encode("utf-8")).hexdigest().upper()
        return digest, digest

    cpu = _run_wmic(["cpu", "get", "ProcessorId"])
    board = _run_wmic(["baseboard", "get", "SerialNumber"])
    disk = _run_wmic(["diskdrive", "get", "SerialNumber"])
    mac = _run_wmic(["nic", "where", "NetEnabled=true", "get", "MACAddress"])

    parts = [p for p in (cpu, board, disk, mac) if p]
    if not parts:
        parts = [str(uuid.getnode())]

    s2 = hashlib.md5("|".join(parts).encode("utf-8")).hexdigest().upper()
    s3 = hashlib.md5(s2.encode("utf-8")).hexdigest().upper()
    return s2, s3
