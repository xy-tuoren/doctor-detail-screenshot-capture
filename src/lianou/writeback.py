from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

UPDATE_PATH = "/api/doctorExt/UpdateDoctorMedical"

PASCAL_FIELD_MAP = {
    "recordDate": "recordDate",
    "recordExpireDate": "recordExpireDate",
    "healthCommissionBase": "healthCommissionBase",
    "institutionBase": "institutionBase",
}

IMAGE_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


@dataclass
class WritebackResult:
    a_id: Any
    doctor_name: str
    ok: bool
    message: str
    fields: dict[str, str] = field(default_factory=dict)


def build_update_url(api_cfg: dict[str, Any]) -> str:
    base = str(api_cfg["baseUrl"]).rstrip("/")
    query = (
        f"nonce={api_cfg['nonce']}"
        f"&timestamp={api_cfg['timestamp']}"
        f"&sign={api_cfg['sign']}"
    )
    return f"{base}{UPDATE_PATH}?{query}"


def encode_image_base64(image_path: Path, *, data_uri: bool = False) -> str:
    raw = image_path.read_bytes()
    encoded = base64.b64encode(raw).decode("ascii")
    if data_uri:
        mime = IMAGE_MIME.get(image_path.suffix.lower(), "image/png")
        return f"data:{mime};base64,{encoded}"
    return encoded


class LianouWritebackClient:
    """Adapter for the Lianou UpdateDoctorMedical API."""

    def __init__(self, api_cfg: dict[str, Any]):
        self.api_cfg = api_cfg
        self.timeout = int(api_cfg.get("requestTimeoutSeconds", 60))
        self.image_data_uri = bool(api_cfg.get("imageDataUri", False))

    def update_from_payload(self, payload: dict[str, Any]) -> WritebackResult:
        from src.reconcile.to_supplement import postable_body

        body = postable_body(payload)
        a_id = body.get("AId")
        doctor_name = str(body.get("doctorName") or "")

        if a_id is None or not body.get("DoctorFileId") or not doctor_name:
            return WritebackResult(
                a_id=a_id,
                doctor_name=doctor_name,
                ok=False,
                message="missing required AId/DoctorFileId/doctorName",
                fields={},
            )

        try:
            response = self._post(body)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            return WritebackResult(
                a_id=a_id, doctor_name=doctor_name, ok=False, message=str(exc), fields={}
            )

        ok = response.get("code") == 1
        return WritebackResult(
            a_id=a_id,
            doctor_name=doctor_name,
            ok=ok,
            message=str(response.get("msg") or response.get("data") or ""),
            fields={k: str(v) for k, v in body.items() if k not in ("AId", "DoctorFileId", "doctorName")},
        )

    def update(
        self,
        *,
        a_id: Any,
        doctor_file_id: str,
        doctor_name: str,
        medical_institution_type: int | None = None,
        fields: dict[str, str],
    ) -> WritebackResult:
        if a_id is None or not doctor_file_id or not doctor_name:
            return WritebackResult(
                a_id=a_id,
                doctor_name=doctor_name,
                ok=False,
                message="missing required AId/DoctorFileId/DoctorName",
                fields=fields,
            )

        body: dict[str, Any] = {
            "AId": a_id,
            "DoctorFileId": doctor_file_id,
            "doctorName": doctor_name,
        }
        if medical_institution_type:
            body["MedicalInstitutionType"] = medical_institution_type
        for key, value in fields.items():
            pascal = PASCAL_FIELD_MAP.get(key)
            if pascal and value:
                body[pascal] = value

        try:
            payload = self._post(body)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            return WritebackResult(
                a_id=a_id, doctor_name=doctor_name, ok=False, message=str(exc), fields=fields
            )

        ok = payload.get("code") == 1
        return WritebackResult(
            a_id=a_id,
            doctor_name=doctor_name,
            ok=ok,
            message=str(payload.get("msg") or payload.get("data") or ""),
            fields=fields,
        )

    def update_image(
        self,
        *,
        a_id: Any,
        doctor_file_id: str,
        doctor_name: str,
        field_name: str,
        image_path: Path,
        medical_institution_type: int | None = None,
    ) -> WritebackResult:
        if not image_path.exists():
            return WritebackResult(
                a_id=a_id,
                doctor_name=doctor_name,
                ok=False,
                message=f"image not found: {image_path}",
                fields={field_name: str(image_path)},
            )
        encoded = encode_image_base64(image_path, data_uri=self.image_data_uri)
        return self.update(
            a_id=a_id,
            doctor_file_id=doctor_file_id,
            doctor_name=doctor_name,
            medical_institution_type=medical_institution_type,
            fields={field_name: encoded},
        )

    def _post(self, body: dict[str, Any]) -> dict[str, Any]:
        url = build_update_url(self.api_cfg)
        data = json.dumps(body).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "sign": str(self.api_cfg.get("headerSign", "lo")),
        }
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))


def apply_supplement_plan(
    plan: list[dict[str, Any]] | dict[str, Any],
    api_cfg: dict[str, Any],
    *,
    dry_run: bool = True,
    include_images: bool = False,
) -> list[WritebackResult]:
    from src.reconcile.to_supplement import iter_payloads, postable_body

    client = LianouWritebackClient(api_cfg)
    results: list[WritebackResult] = []

    for payload in iter_payloads(plan):
        body = postable_body(payload, include_images=include_images)
        if not has_writable_fields(payload, include_images=include_images):
            continue

        doctor_name = str(body.get("doctorName") or "")
        a_id = body.get("AId")

        if dry_run:
            from src.reconcile.api_payload import REQUIRED_API_KEYS

            fields = {k: str(v) for k, v in body.items() if k not in REQUIRED_API_KEYS}
            results.append(
                WritebackResult(
                    a_id=a_id,
                    doctor_name=doctor_name,
                    ok=True,
                    message="dry-run",
                    fields=fields,
                )
            )
            continue

        results.append(client.update_from_payload({**payload, **body}))
    return results
