"""电子证照预览 URL 生成。

逆向自机构端客户端 ``DoctorRegUnit.CPL.dll``：
点击「查看电子证照」时，客户端用 AES-128-CBC 加密
``{Doctor_GID};{Doctor_RegisterGID}`` 生成 ``encry`` 参数，
拼接成 ``https://license.wsb003.cn/license/doctor?ty=d&encry=...&f=D_U``。

参数 ``df``（时间戳+MD5 签名）服务端不校验，可省略。

仅依赖 ``pycryptodome``（已在 capture-institution extra 中）。
"""
from __future__ import annotations

import base64

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

_KEY = b"mINKE1wae9mPa9sY"
_IV = bytes.fromhex("1234567890abcdef1234567890abcdef")
_BASE = "https://license.wsb003.cn/license/doctor"


def make_electronic_license_url(doctor_gid: str, register_gid: str) -> str:
    """生成医师执业证书电子证照预览 URL。

    Args:
        doctor_gid: 医师 GUID（SOAP 列表 ``Doctor_GID``）
        register_gid: 注册记录 GUID（SOAP 列表 ``Doctor_RegisterGID``）

    Returns:
        可在浏览器直接打开的预览 URL。
    """
    plain = f"{doctor_gid};{register_gid}".encode("utf-8")
    cipher = AES.new(_KEY, AES.MODE_CBC, iv=_IV)
    encry = base64.b64encode(cipher.encrypt(pad(plain, AES.block_size))).decode("ascii")
    return f"{_BASE}?ty=d&encry={encry}&f=D_U"
