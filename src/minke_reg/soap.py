from __future__ import annotations

import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any
from xml.sax.saxutils import escape


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _find_text(parent: ET.Element, local: str) -> str:
    for child in parent.iter():
        if _local_name(child.tag) == local:
            return (child.text or "").strip()
    return ""


class SoapClient:
    def __init__(self, service_url: str, namespace: str, timeout: int = 120) -> None:
        self.service_url = service_url
        self.namespace = namespace.rstrip("/") + "/"
        self.timeout = timeout

    def call(
        self,
        action: str,
        body_xml: str,
        header_xml: str = "",
    ) -> str:
        header_block = header_xml or ""
        envelope = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            'xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
            'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            f"<soap:Header>{header_block}</soap:Header>"
            f"<soap:Body>{body_xml}</soap:Body>"
            "</soap:Envelope>"
        )
        payload = envelope.encode("utf-8")
        headers = {
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": f'"{action}"',
            "User-Agent": (
                "Mozilla/4.0 (compatible; MSIE 6.0; MS Web Services Client Protocol 4.0.30319.42000)"
            ),
        }
        req = urllib.request.Request(
            self.service_url,
            data=payload,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"SOAP HTTP {exc.code}: {body[:500]}") from exc

    def call_operation(
        self,
        operation: str,
        inner_fields: dict[str, Any],
        header_xml: str = "",
    ) -> str:
        fields = "".join(
            f"<{key}>{escape(str(value))}</{key}>"
            for key, value in inner_fields.items()
        )
        body = (
            f'<{operation} xmlns="{self.namespace}">'
            f"{fields}"
            f"</{operation}>"
        )
        action = f"{self.namespace}{operation}"
        return self.call(action, body, header_xml=header_xml)


def build_mk_header(
    namespace: str,
    user_id: str,
    key_result: str,
    unit_guid: str,
    code: str = "",
    p1: str = "",
    p2: str = "",
) -> str:
    ns = namespace.rstrip("/") + "/"
    parts = [
        f"<UserId>{escape(user_id)}</UserId>",
        f"<KeyResult>{escape(key_result)}</KeyResult>",
        f"<UnitGuid>{escape(unit_guid)}</UnitGuid>",
    ]
    if code:
        parts.insert(0, f"<Code>{escape(code)}</Code>")
    if p1:
        parts.insert(-3 if code else 0, f"<p1>{escape(p1)}</p1>")
    if p2:
        parts.insert(-3 if code else 0, f"<p2>{escape(p2)}</p2>")
    inner = "".join(parts)
    return f'<MKSoapHeader xmlns="{ns}">{inner}</MKSoapHeader>'


def parse_login_user(soap_xml: str) -> dict[str, str]:
    root = ET.fromstring(soap_xml)
    user_elem = None
    for elem in root.iter():
        if _local_name(elem.tag) == "aUser":
            user_elem = elem
            break
    if user_elem is None:
        raise RuntimeError("Login response missing aUser")

    result: dict[str, str] = {}
    for child in list(user_elem):
        result[_local_name(child.tag)] = (child.text or "").strip()

    login_result = _find_text(root, "LoginResult")
    if login_result and login_result != "0":
        check_result = _find_text(root, "CheckLoginResult")
        raise RuntimeError(
            f"Login failed: LoginResult={login_result or check_result or 'unknown'}"
        )
    return result


def extract_error_message(soap_xml: str) -> str:
    return _find_text(ET.fromstring(soap_xml), "aErrorMsg")
