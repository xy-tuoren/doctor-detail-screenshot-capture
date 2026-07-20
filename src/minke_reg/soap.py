from __future__ import annotations

import http.client
import ipaddress
import socket
import threading
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any, Literal
from xml.sax.saxutils import escape

# Clash 等工具的 fake-ip 默认池；解析到此段时 TCP 直连会超时，
# 表现为 Login/列表偶发仍通、GetRegDetailForUnit 大面积超时。
_FAKE_IP_NET = ipaddress.ip_network("198.18.0.0/15")


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def is_clash_fake_ip(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip) in _FAKE_IP_NET
    except ValueError:
        return False


def resolve_service_host(service_url: str) -> tuple[str, str]:
    """Return (hostname, resolved_ip)."""
    host = urllib.parse.urlparse(service_url).hostname or ""
    if not host:
        raise ValueError(f"service_url missing host: {service_url}")
    ip = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)[0][4][0]
    return host, ip


def check_minke_service_route(
    service_url: str,
    *,
    on_fake_ip: Literal["warn", "error"] = "warn",
) -> str | None:
    """检测机构端 SOAP 主机是否被解析到代理 fake-ip。

    返回提示文案；``on_fake_ip='error'`` 时直接抛错，避免全量预取空转超时。
    """
    try:
        host, ip = resolve_service_host(service_url)
    except OSError as exc:
        msg = f"无法解析机构端主机（{service_url}）：{exc}"
        if on_fake_ip == "error":
            raise RuntimeError(msg) from exc
        print(f"[WARN] {msg}", flush=True)
        return msg
    if not is_clash_fake_ip(ip):
        return None
    msg = (
        f"机构端主机 {host} 解析到代理 fake-ip {ip}（198.18.0.0/15）。"
        "这会导致 GetRegDetailForUnit 等详情接口超时。"
        "请关闭 Clash/系统代理，或将 jgd.wsb002.cn 设为 DIRECT 后重试。"
    )
    if on_fake_ip == "error":
        raise RuntimeError(msg)
    print(f"[WARN] {msg}", flush=True)
    return msg


def _find_text(parent: ET.Element, local: str) -> str:
    for child in parent.iter():
        if _local_name(child.tag) == local:
            return (child.text or "").strip()
    return ""


class SoapClient:
    def __init__(
        self,
        service_url: str,
        namespace: str,
        timeout: int = 120,
        *,
        reuse_connection: bool = False,
    ) -> None:
        self.service_url = service_url
        self.namespace = namespace.rstrip("/") + "/"
        self.timeout = timeout
        self.reuse_connection = reuse_connection
        if reuse_connection:
            parsed = urllib.parse.urlparse(service_url)
            self._host = parsed.hostname or ""
            self._path = parsed.path or "/"
            self._conn_local = threading.local()

    def call(
        self,
        action: str,
        body_xml: str,
        header_xml: str = "",
    ) -> str:
        if self.reuse_connection:
            return self._call_reuse(action, body_xml, header_xml)
        return self._call_urlopen(action, body_xml, header_xml)

    def _build_envelope(self, body_xml: str, header_xml: str) -> bytes:
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
        return envelope.encode("utf-8")

    def _soap_headers(self, action: str, *, keep_alive: bool = False) -> dict[str, str]:
        headers = {
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": f'"{action}"',
            "User-Agent": (
                "Mozilla/4.0 (compatible; MSIE 6.0; MS Web Services Client Protocol 4.0.30319.42000)"
            ),
        }
        if keep_alive:
            headers["Connection"] = "keep-alive"
        return headers

    def _call_urlopen(self, action: str, body_xml: str, header_xml: str) -> str:
        payload = self._build_envelope(body_xml, header_xml)
        req = urllib.request.Request(
            self.service_url,
            data=payload,
            headers=self._soap_headers(action),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"SOAP HTTP {exc.code}: {body[:500]}") from exc

    def _call_reuse(self, action: str, body_xml: str, header_xml: str) -> str:
        payload = self._build_envelope(body_xml, header_xml)
        conn = getattr(self._conn_local, "conn", None)
        if conn is None:
            conn = http.client.HTTPSConnection(self._host, timeout=self.timeout)
            self._conn_local.conn = conn
        try:
            conn.request(
                "POST",
                self._path,
                body=payload,
                headers=self._soap_headers(action, keep_alive=True),
            )
            resp = conn.getresponse()
            data = resp.read().decode("utf-8", errors="replace")
            if resp.status >= 400:
                raise RuntimeError(f"SOAP HTTP {resp.status}: {data[:500]}")
            return data
        except (http.client.HTTPException, OSError, RuntimeError):
            self._conn_local.conn = None
            raise

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


def login_failure_message(soap_xml: str, *, phase: str = "Login") -> str:
    root = ET.fromstring(soap_xml)
    check_result = _find_text(root, "CheckLoginResult")
    login_result = _find_text(root, "LoginResult")
    error_msg = _find_text(root, "aErrorMsg") or _find_text(root, "ErrorMsg")

    if check_result and not check_result.isdigit():
        return f"机构端{phase}失败：{check_result}"
    if error_msg:
        return f"机构端{phase}失败：{error_msg}"
    code = login_result or check_result or "unknown"
    return f"机构端{phase}失败：LoginResult={code}"


# CheckLogin 成功码：历史为 "0"；现网亦可能返回 "C"（仍带 UserId/KeyResult）
_CHECK_LOGIN_OK = frozenset({"0", "C"})


def assert_login_success(soap_xml: str, *, phase: str = "Login") -> None:
    root = ET.fromstring(soap_xml)
    login_result = _find_text(root, "LoginResult")
    check_result = _find_text(root, "CheckLoginResult")
    if login_result == "0":
        return
    if phase == "CheckLogin" and check_result in _CHECK_LOGIN_OK:
        return
    if check_result and check_result.isdigit() and int(check_result) != 0:
        raise RuntimeError(login_failure_message(soap_xml, phase=phase))
    if login_result and login_result != "0":
        raise RuntimeError(login_failure_message(soap_xml, phase=phase))
    if phase == "CheckLogin" and check_result and check_result not in _CHECK_LOGIN_OK:
        if not check_result.isdigit():
            raise RuntimeError(login_failure_message(soap_xml, phase=phase))


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

    assert_login_success(soap_xml, phase="Login")
    return result


def extract_error_message(soap_xml: str) -> str:
    return _find_text(ET.fromstring(soap_xml), "aErrorMsg")
