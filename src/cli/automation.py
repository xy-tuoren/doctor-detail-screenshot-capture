from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from src.api.config import project_root

PS1 = "automation/ps1/capture-doctor-details.ps1"
SETUP_OCR = "automation/ps1/setup-ocr-env.ps1"
VERIFY_CAPTURES = "automation/py/verify_captures.py"


@dataclass(frozen=True)
class AutomationTask:
    ps1_mode: str | None = None
    list_entry: str | None = None
    ocr_setup: bool = False
    python_script: str | None = None


AUTOMATION_TASKS: dict[tuple[str, str], AutomationTask] = {
    ("capture", "Main"): AutomationTask(ps1_mode="LoginAndSearchNames", list_entry="Main"),
    ("capture", "Multi"): AutomationTask(ps1_mode="LoginAndSearchNames", list_entry="Multi"),
    ("calibrate", "Main"): AutomationTask(ps1_mode="CalibrateAll"),
    ("export", "Main"): AutomationTask(ps1_mode="Export", list_entry="Main"),
    ("export", "Multi"): AutomationTask(ps1_mode="Export", list_entry="Multi"),
    ("export-calibrate", "Main"): AutomationTask(ps1_mode="ExportCalibrate"),
    ("login-home", "Main"): AutomationTask(ps1_mode="LoginToHome"),
    ("open-list-capture", "Main"): AutomationTask(
        ps1_mode="OpenListAndSearchNames", list_entry="Main"
    ),
    ("open-list-capture", "Multi"): AutomationTask(
        ps1_mode="OpenListAndSearchNames", list_entry="Multi"
    ),
    ("verify-captures", "Main"): AutomationTask(
        ocr_setup=True, python_script=VERIFY_CAPTURES
    ),
}


def describe_task(task: AutomationTask, root: Path) -> str:
    if task.python_script:
        parts = []
        if task.ocr_setup:
            parts.append(f"powershell -File {root / SETUP_OCR}")
        parts.append(f"python {root / task.python_script}")
        return " ; ".join(parts)
    args = ["-Mode", task.ps1_mode]
    if task.list_entry:
        args.extend(["-ListEntry", task.list_entry])
    return f"powershell -File {root / PS1} {' '.join(args)}"


def run_task(task: AutomationTask, extra: list[str] | None = None) -> int:
    root = project_root()
    extra = extra or []
    venv_python = root / ".venv" / "Scripts" / "python.exe"

    if not (root / "config.json").exists():
        print("[ERROR] config.json not found.", file=sys.stderr)
        return 1

    if task.ocr_setup:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(root / SETUP_OCR),
            ],
            cwd=root,
        )
        if result.returncode != 0:
            return result.returncode

    if task.python_script:
        if not venv_python.exists():
            print(f"[ERROR] venv python not found: {venv_python}", file=sys.stderr)
            return 1
        result = subprocess.run(
            [str(venv_python), str(root / task.python_script), *extra],
            cwd=root,
        )
        return result.returncode

    ps1_args = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(root / PS1),
        "-Mode",
        task.ps1_mode,
    ]
    if task.list_entry:
        ps1_args.extend(["-ListEntry", task.list_entry])
    ps1_args.extend(extra)

    result = subprocess.run(ps1_args, cwd=root)
    return result.returncode
