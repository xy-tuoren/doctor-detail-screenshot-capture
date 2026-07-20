r"""轮询 Mongo practiceHospitalJobs，执行全量报告生成并导入。

供 hospital-admin「获取数据」按钮使用：网站只创建 status=queued 的任务；
本脚本在装有本仓库 + config.json 的机器上常驻（或定时）领取并执行。

用法（PowerShell，项目根目录）：

    # 常驻轮询（默认每 10 秒）
    .\.venv\Scripts\python.exe scripts\practice_hospital_job_worker.py

    # 只处理一单后退出（适合任务计划程序）
    .\.venv\Scripts\python.exe scripts\practice_hospital_job_worker.py --once

依赖：项目根 .env 中 MONGO_URI；config.json（机构端 + 莲藕）。
全量约 10–25 分钟，勿在 Cursor Agent 前台 Shell 长跑。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bson import ObjectId
from pymongo import ASCENDING, MongoClient, ReturnDocument

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_XLSX = ROOT / "workspace" / "artifacts" / "医生执业医院信息_20260706.xlsx"
JOBS = "practiceHospitalJobs"
REPORT_ID_RE = re.compile(r"reportId:\s*([0-9a-fA-F]{24})")


def _load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _python() -> str:
    venv_py = ROOT / ".venv" / "Scripts" / "python.exe"
    if venv_py.is_file():
        return str(venv_py)
    return sys.executable


def _run_cmd(cmd: list[str], phase: str) -> tuple[int, str]:
    print(f"[worker] {phase}: {' '.join(cmd)}", flush=True)
    proc = subprocess.run(
        cmd,
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    out = (proc.stdout or "") + ("\n" if proc.stdout and proc.stderr else "") + (proc.stderr or "")
    if out.strip():
        # 控制台打尾部，避免刷屏
        tail = out if len(out) <= 4000 else out[-4000:]
        print(tail, flush=True)
    return proc.returncode, out


def _parse_report_id(text: str) -> ObjectId | None:
    m = REPORT_ID_RE.search(text)
    if not m:
        return None
    try:
        return ObjectId(m.group(1))
    except Exception:
        return None


def claim_job(db) -> dict[str, Any] | None:
    return db[JOBS].find_one_and_update(
        {"status": "queued"},
        {
            "$set": {
                "status": "running",
                "phase": "claimed",
                "startedAt": _now(),
                "updatedAt": _now(),
                "error": None,
            }
        },
        sort=[("createdAt", ASCENDING)],
        return_document=ReturnDocument.AFTER,
    )


def set_job(db, job_id, **fields: Any) -> None:
    fields = {**fields, "updatedAt": _now()}
    db[JOBS].update_one({"_id": job_id}, {"$set": fields})


def process_job(db, job: dict[str, Any], config: Path) -> None:
    job_id = job["_id"]
    drop_existing = bool(job.get("dropExisting"))
    skip_institution = bool(job.get("skipInstitutionFetch"))
    py = _python()

    set_job(db, job_id, phase="building_report")
    build_cmd = [py, "-m", "src.cli", "build-practice-hospital-report", "--config", str(config)]
    if skip_institution:
        build_cmd.append("--skip-institution-fetch")
    code, build_out = _run_cmd(build_cmd, "build-report")
    if code != 0:
        set_job(
            db,
            job_id,
            status="failed",
            phase="failed_build",
            finishedAt=_now(),
            error=(build_out[-2000:] if build_out else f"build exit {code}"),
            logTail=build_out[-4000:] if build_out else "",
        )
        return

    if not DEFAULT_XLSX.is_file():
        set_job(
            db,
            job_id,
            status="failed",
            phase="failed_build",
            finishedAt=_now(),
            error=f"报告文件不存在: {DEFAULT_XLSX}",
        )
        return

    set_job(db, job_id, phase="importing_mongo")
    export_cmd = [
        py,
        str(ROOT / "scripts" / "export_practice_report_to_mongo.py"),
        "-x",
        str(DEFAULT_XLSX),
    ]
    if drop_existing:
        export_cmd.append("--drop-existing")
    code, export_out = _run_cmd(export_cmd, "export-mongo")
    if code != 0:
        set_job(
            db,
            job_id,
            status="failed",
            phase="failed_import",
            finishedAt=_now(),
            error=(export_out[-2000:] if export_out else f"export exit {code}"),
            logTail=export_out[-4000:] if export_out else "",
        )
        return

    report_id = _parse_report_id(export_out)
    if report_id is None:
        # 兜底：取最新 ready 批次
        latest = db.importReports.find_one({"status": "ready"}, sort=[("importedAt", -1)])
        report_id = latest["_id"] if latest else None

    set_job(
        db,
        job_id,
        status="succeeded",
        phase="done",
        finishedAt=_now(),
        reportId=report_id,
        error=None,
        logTail=(export_out[-2000:] if export_out else ""),
    )
    print(f"[worker] job {job_id} succeeded reportId={report_id}", flush=True)


def ensure_indexes(db) -> None:
    db[JOBS].create_index([("status", ASCENDING), ("createdAt", ASCENDING)])


def main() -> int:
    parser = argparse.ArgumentParser(description="执业医院报告任务 Worker（Mongo 轮询）")
    parser.add_argument("--once", action="store_true", help="最多处理一单后退出（无任务也退出）")
    parser.add_argument("--poll-interval", type=float, default=10.0, help="无任务时休眠秒数")
    parser.add_argument("--db-name", default="hospital_admin")
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "config.json",
        help="机构端/莲藕配置",
    )
    args = parser.parse_args()

    _load_dotenv(ROOT / ".env")
    mongo_uri = os.environ.get("MONGO_URI")
    if not mongo_uri:
        print("[ERROR] 未设置 MONGO_URI（项目根 .env）", file=sys.stderr)
        return 1
    if not args.config.is_file():
        print(f"[ERROR] 配置不存在: {args.config}", file=sys.stderr)
        return 1

    client = MongoClient(mongo_uri)
    db = client[args.db_name]
    ensure_indexes(db)
    print(f"[worker] 监听 {args.db_name}.{JOBS}（interval={args.poll_interval}s）", flush=True)

    while True:
        job = claim_job(db)
        if job:
            print(f"[worker] 领取任务 {job['_id']}", flush=True)
            try:
                process_job(db, job, args.config.resolve())
            except Exception as exc:
                set_job(
                    db,
                    job["_id"],
                    status="failed",
                    phase="failed_exception",
                    finishedAt=_now(),
                    error=str(exc)[:2000],
                )
                print(f"[worker] 异常: {exc}", file=sys.stderr, flush=True)
            if args.once:
                break
            continue
        if args.once:
            print("[worker] 无 queued 任务，退出", flush=True)
            break
        time.sleep(max(1.0, args.poll_interval))

    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
