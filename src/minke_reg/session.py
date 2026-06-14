from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .constants import EMPTY_GUID, NS_DOCTOR_UNIT, NS_LOGIN
from .machine import build_machine_fingerprint
from .soap import SoapClient, build_mk_header, parse_login_user


@dataclass(frozen=True)
class MinkeSession:
    user_id: str
    key_result: str
    unit_guid: str
    organ_id: str
    organ_name: str
    login_id: str

    def login_header(self) -> str:
        return build_mk_header(
            NS_LOGIN,
            self.user_id,
            self.key_result,
            EMPTY_GUID,
        )

    def doctor_header(self) -> str:
        return build_mk_header(
            NS_DOCTOR_UNIT,
            self.user_id,
            self.key_result,
            self.unit_guid,
        )


def login_minke_reg(cfg: dict[str, Any]) -> MinkeSession:
    client = SoapClient(
        str(cfg["loginServiceUrl"]),
        NS_LOGIN,
        timeout=int(cfg.get("requestTimeoutSeconds", 120)),
    )
    product_id = str(cfg["productId"])
    login_id = str(cfg["loginUser"])
    password = str(cfg["loginPassword"])
    s2, s3 = build_machine_fingerprint()

    guest_header = build_mk_header(
        NS_LOGIN,
        EMPTY_GUID,
        "Minke",
        EMPTY_GUID,
    )

    verify_resp = client.call_operation("GetNewVerifyCode", {}, header_xml=guest_header)
    verify_code = _text_from_response(verify_resp, "GetNewVerifyCodeResult")
    if not verify_code:
        raise RuntimeError("GetNewVerifyCode returned empty code")

    check_user = _blank_user(product_id, login_id, password)
    check_body = (
        f'<CheckLogin xmlns="{NS_LOGIN}">'
        f"<aUser>{_user_inner_xml(check_user)}</aUser>"
        "</CheckLogin>"
    )
    client.call(f"{NS_LOGIN}CheckLogin", check_body, header_xml=guest_header)

    login_user = _blank_user(product_id, login_id, password)
    login_user.update(
        {
            "LoginFrom": "Doctor",
            "VerifyCode": verify_code,
            "KeyResult": "EmptyKeyString",
            "S2": s2,
            "S3": s3,
        }
    )
    login_body = (
        f'<Login xmlns="{NS_LOGIN}">'
        f"<aUser>{_user_inner_xml(login_user)}</aUser>"
        "</Login>"
    )
    login_resp = client.call(f"{NS_LOGIN}Login", login_body, header_xml=guest_header)
    parsed = parse_login_user(login_resp)

    user_id = parsed.get("UserId") or EMPTY_GUID
    key_result = parsed.get("KeyResult") or ""
    unit_guid = parsed.get("OrganId") or EMPTY_GUID
    if not key_result or unit_guid == EMPTY_GUID:
        raise RuntimeError("Login succeeded but session tokens are missing")

    return MinkeSession(
        user_id=user_id,
        key_result=key_result,
        unit_guid=unit_guid,
        organ_id=unit_guid,
        organ_name=parsed.get("OrganName", ""),
        login_id=login_id,
    )


def _blank_user(product_id: str, login_id: str, password: str) -> dict[str, str]:
    return {
        "IsNewKey": "false",
        "UseWeChatLogin": "false",
        "PasswordIsExpired": "false",
        "ProductId": product_id,
        "UserId": EMPTY_GUID,
        "OrganId": EMPTY_GUID,
        "OrganLayerLevel": "0",
        "RegionId": EMPTY_GUID,
        "RegionLayerLevel": "0",
        "LoginId": login_id,
        "Password": password,
        "VerifyCode": "",
        "KeyResult": "",
        "S1": "",
        "S2": "",
        "S3": "",
        "LoginTime": "0001-01-01T00:00:00",
    }


def _user_inner_xml(user: dict[str, str]) -> str:
    parts = []
    for key, value in user.items():
        parts.append(f"<{key}>{_escape_xml(value)}</{key}>")
    return "".join(parts)


def _escape_xml(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _text_from_response(soap_xml: str, local_name: str) -> str:
    import xml.etree.ElementTree as ET

    root = ET.fromstring(soap_xml)
    for elem in root.iter():
        if elem.tag.rsplit("}", 1)[-1] == local_name:
            return (elem.text or "").strip()
    return ""
