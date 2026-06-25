"""卫健委医师执业注册信息批量查询与截图（内联自原 batch-doctor-query 子项目）。

核心入口 `batch_query(doctors, ...)`；由 src.capture.nhc 封装供管线在进程内调用。
原 argparse CLI 外壳已移除，统一改由 `python -m src.cli capture-nhc` 驱动。
"""

import base64
import http.client
import io
import json
import os
import random
import re
import socket
import time
from collections import Counter
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

import ddddocr
from PIL import Image, ImageEnhance, ImageFilter
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
from playwright_stealth import Stealth

# --- 可选引擎 ---
try:
    import cv2
    import numpy as np
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False

# ---------- 配置默认值 ----------
DEFAULT_PROVINCE = "广东省"
DEFAULT_HOSPITAL = "莲藕健康医院"
DEFAULT_INTERVAL = 60  # 秒
OUTPUT_DIR = "screenshots"
FAILURE_LOG = "failures.log"
DEFAULT_CLASH_API = "unix:///tmp/verge/verge-mihomo.sock"
DEFAULT_CLASH_GROUP = "批量查询轮换"
DEFAULT_PROXY = "http://127.0.0.1:7897"
LEAF_PROXY_TYPES = frozenset({
    "Shadowsocks", "ShadowsocksR", "Snell", "Trojan", "Vmess", "Vless",
    "Hysteria", "Hysteria2", "TUIC", "WireGuard", "Socks5", "Http",
})


# ---------- 工具函数 ----------


def set_output_dir(path: str):
    global OUTPUT_DIR
    OUTPUT_DIR = path


def set_failure_log(path: str):
    global FAILURE_LOG
    FAILURE_LOG = path


def ensure_output_dir():
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def find_playwright_chromium() -> str | None:
    """查找本机已安装的 Playwright Chromium（全局缓存在 ms-playwright）。

    跨平台：优先 PLAYWRIGHT_BROWSERS_PATH，其次 Windows / macOS 默认缓存目录。
    """
    roots = []
    env_root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if env_root:
        roots.append(env_root)
    local_appdata = os.environ.get("LOCALAPPDATA")
    if local_appdata:
        roots.append(os.path.join(local_appdata, "ms-playwright"))
    roots.append(os.path.expanduser("~/Library/Caches/ms-playwright"))

    # (相对可执行文件路径)，按平台分别尝试
    rel_paths = [
        ("chrome-win", "chrome.exe"),
        ("chrome-mac-arm64", "Google Chrome for Testing.app", "Contents",
         "MacOS", "Google Chrome for Testing"),
        ("chrome-mac", "Google Chrome for Testing.app", "Contents",
         "MacOS", "Google Chrome for Testing"),
        ("chrome-linux", "chrome"),
    ]

    candidates = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in os.listdir(root):
            if not name.startswith("chromium-"):
                continue
            for rel in rel_paths:
                base = os.path.join(root, name, *rel)
                if os.path.isfile(base):
                    candidates.append(base)

    if not candidates:
        return None
    return sorted(candidates)[-1]


def launch_chromium(pw, headless: bool, stealth: bool = True):
    """优先用 Playwright 默认浏览器；缺 headless shell 时复用已有 Chromium。"""
    launch_args = {"headless": headless}
    if stealth:
        launch_args["args"] = [
            "--disable-blink-features=AutomationControlled",
            "--no-sandbox",
        ]
    try:
        return pw.chromium.launch(**launch_args)
    except Exception as e:
        if "Executable doesn't exist" not in str(e):
            raise
        chromium = find_playwright_chromium()
        if chromium:
            log(f"⚠ 改用已安装的 Playwright Chromium: {chromium}")
            launch_args["executable_path"] = chromium
            return pw.chromium.launch(**launch_args)
        log("⚠ Playwright Chromium 未找到，改用本机 Google Chrome")
        launch_args["channel"] = "chrome"
        return pw.chromium.launch(**launch_args)


def safe_text(el):
    """安全获取元素文本"""
    try:
        return el.text_content().strip()
    except Exception:
        return ""


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")


def log_failure(name: str, reason: str):
    """追加失败记录到 failures.log，不保存失败截图"""
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{name}\t{reason}\n"
    with open(FAILURE_LOG, "a", encoding="utf-8") as f:
        f.write(line)
    log(f"  📝 失败记录: {reason}")


class _UnixHTTPConnection(http.client.HTTPConnection):
    """Clash Verge Rev 在 macOS 上常用 Unix Socket 暴露 External Controller。"""

    def __init__(self, unix_path: str):
        super().__init__("localhost")
        self._unix_path = unix_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self._unix_path)


class ClashRotator:
    """通过 Clash External Controller API 在专用代理组内轮换节点。"""

    def __init__(self, api_base: str, group_name: str, secret: str | None = None):
        self.api_base = api_base.rstrip("/")
        self.group_name = group_name
        self.secret = secret
        self._nodes: list[str] = []
        self._index = -1
        self._load_nodes()

    @property
    def node_count(self) -> int:
        return len(self._nodes)

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.secret:
            headers["Authorization"] = f"Bearer {self.secret}"
        return headers

    def _request_json(self, method: str, path: str, body: dict | None = None) -> dict:
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        headers = self._headers()

        if self.api_base.startswith("unix://"):
            conn = _UnixHTTPConnection(self.api_base[len("unix://"):])
            conn.timeout = 5
            try:
                conn.request(method, path, body=data, headers=headers)
                resp = conn.getresponse()
                raw = resp.read().decode("utf-8")
                if resp.status >= 400:
                    raise HTTPError(
                        f"{self.api_base}{path}", resp.status, resp.reason,
                        resp.headers, io.BytesIO(raw.encode("utf-8")),
                    )
                return json.loads(raw) if raw else {}
            finally:
                conn.close()

        url = f"{self.api_base}{path}"
        req = Request(url, data=data, headers=headers, method=method)
        with urlopen(req, timeout=5) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}

    def _load_nodes(self):
        all_data = self._request_json("GET", "/proxies")
        proxies = all_data.get("proxies", {})
        group = proxies.get(self.group_name)
        if not group:
            group = self._request_json("GET", f"/proxies/{quote(self.group_name, safe='')}")

        candidates = group.get("all", [])
        nodes: list[str] = []
        for name in candidates:
            if name in {"DIRECT", "REJECT", "GLOBAL", "PASS"}:
                continue
            if name.startswith(("剩余流量", "套餐到期", "看公告")):
                continue
            info = proxies.get(name, {})
            if info.get("type") in LEAF_PROXY_TYPES:
                nodes.append(name)

        if not nodes:
            nodes = [
                name for name in candidates
                if name not in {"DIRECT", "REJECT", "GLOBAL", "PASS"}
                and not name.startswith(("剩余流量", "套餐到期", "看公告"))
            ]

        self._nodes = nodes
        now = group.get("now")
        if now in self._nodes:
            self._index = self._nodes.index(now)

    def current_node(self) -> str | None:
        if self._index < 0 or self._index >= len(self._nodes):
            return None
        return self._nodes[self._index]

    def rotate(self) -> str | None:
        """切换到组内下一个节点，成功返回节点名。"""
        if not self._nodes:
            log(f"  ⚠ Clash 组「{self.group_name}」没有可轮换节点")
            return None
        self._index = (self._index + 1) % len(self._nodes)
        node = self._nodes[self._index]
        try:
            self._request_json(
                "PUT",
                f"/proxies/{quote(self.group_name, safe='')}",
                {"name": node},
            )
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as e:
            log(f"  ⚠ Clash 切换节点失败: {e}")
            return None
        log(f"  🌐 Clash 已切换节点 → {node}")
        time.sleep(2)
        return node


def _jitter_ms(base_ms: int) -> int:
    """基础等待 + 随机偏移 50~200ms"""
    return max(50, base_ms + random.randint(-200, 200))


def human_delay(base_ms: int = 300):
    """纯 time.sleep + 随机抖动"""
    time.sleep(_jitter_ms(base_ms) / 1000)


def human_wait(page, base_ms: int = 300):
    """Playwright page.wait_for_timeout + 随机抖动（保持页面事件处理）"""
    page.wait_for_timeout(_jitter_ms(base_ms))


# ---------- 执业证书编码 ----------

_CERT_CODE_LABEL_RE = re.compile(
    r"执业证书编码[：:\s]*([A-Za-z0-9][A-Za-z0-9+\-_]*)",
    re.IGNORECASE,
)


def normalize_cert_code(cert: str) -> str:
    return re.sub(r"\s+", "", cert).upper()


def extract_cert_code(drawer_text: str) -> str | None:
    """从详情文本提取执业证书编码（支持纯数字、XC10+…、X1014… 等）。"""
    if not drawer_text:
        return None
    m = _CERT_CODE_LABEL_RE.search(drawer_text)
    if m:
        return m.group(1).strip()
    return None


def cert_code_in_text(cert: str, text: str) -> bool:
    if not cert or not text:
        return False
    norm = normalize_cert_code(cert)
    compact = re.sub(r"\s+", "", text).upper()
    if norm in compact:
        return True
    if norm.replace("+", "") in compact.replace("+", ""):
        return True
    digits = re.sub(r"\D", "", norm)
    if len(digits) >= 10 and digits in re.sub(r"\D", "", compact):
        return True
    return False


def cert_codes_match(extracted: str | None, known: str | None) -> bool:
    if not known:
        return True
    if not extracted or extracted.startswith("unknown_"):
        return False
    a, b = normalize_cert_code(extracted), normalize_cert_code(known)
    if a == b:
        return True
    if a.replace("+", "") == b.replace("+", ""):
        return True
    digits_a = re.sub(r"\D", "", a)
    digits_b = re.sub(r"\D", "", b)
    if digits_a and digits_b and digits_a == digits_b:
        return True
    return False


# ---------- 验证码识别器 ----------


class CaptchaSolver:
    """验证码识别器：ddddocr + cv2 预处理增强"""

    # 置信度阈值
    CONF_HIGH = 0.8   # 高置信度（直接采用）
    CONF_LOW = 0.4    # 低于此值视为不可靠

    def __init__(self):
        self.detector = ddddocr.DdddOcr(det=True, show_ad=False)
        self.ocr_beta = ddddocr.DdddOcr(beta=True, show_ad=False)
        self.ocr_std = ddddocr.DdddOcr(show_ad=False)
        cv2_tag = "+cv2" if HAS_CV2 else "(纯Pillow)"
        log(f"🔍 OCR 引擎: ddddocr {cv2_tag}")

    # ------------------------------------------------------------------
    # 公共入口
    # ------------------------------------------------------------------

    def solve(self, canvas_data_url: str, target_words: list[str]) -> list[dict] | None:
        """解析 canvas data URL，返回按 target_words 顺序排列的点击坐标列表。"""
        img_bytes = self._decode_data_url(canvas_data_url)
        if img_bytes is None:
            return None

        img = Image.open(io.BytesIO(img_bytes))
        return self._solve_ddddocr(img, img_bytes, target_words)

    # ------------------------------------------------------------------
    # ddddocr 路径（含 cv2 预处理增强）
    # ------------------------------------------------------------------

    def _solve_ddddocr(self, img: Image.Image, img_bytes: bytes,
                       target_words: list[str]) -> list[dict] | None:
        """ddddocr 检测 + 多路预处理 OCR + 置信度投票"""

        # --- 检测阶段 ---
        poses = self._detect_chars(img, img_bytes)
        if not poses or len(poses) < len(target_words):
            log(f"  检测到 {len(poses) if poses else 0} 个字符，需要 {len(target_words)} 个")
            return None

        # --- 识别阶段（逐字符多路预处理 + 投票）---
        candidates = []
        for x1, y1, x2, y2 in poses:
            pad = 5
            crop = img.crop((
                max(0, x1 - pad), max(0, y1 - pad),
                min(img.width, x2 + pad), min(img.height, y2 + pad),
            ))

            # 多路预处理 → OCR → 投票
            results, vote_map = self._recognize_with_voting(crop)

            candidates.append({
                "results": results,        # set of all recognized strings
                "vote_map": vote_map,      # {char: vote_count}
                "best_char": max(vote_map, key=vote_map.get) if vote_map else "",
                "best_votes": max(vote_map.values()) if vote_map else 0,
                "x": int((x1 + x2) / 2),
                "y": int((y1 + y2) / 2),
                "bbox": [x1, y1, x2, y2],
            })

        log(f"  ddddocr 候选: {[(c['best_char'], c['best_votes']) for c in candidates]}")

        return self._match_with_confidence(target_words, candidates)

    def _detect_chars(self, img: Image.Image, img_bytes: bytes):
        """字符检测（增强 + 原图双保险）"""
        # 增强图检测
        img_sharp = img.filter(ImageFilter.SHARPEN)
        img_enhanced = ImageEnhance.Contrast(img_sharp).enhance(1.5)
        buf = io.BytesIO(); img_enhanced.save(buf, format="PNG"); buf.seek(0)
        poses = self.detector.detection(buf.read())
        if poses:
            return poses
        # 原图兜底
        return self.detector.detection(img_bytes)

    def _recognize_with_voting(self, crop: Image.Image) -> tuple[set, dict]:
        """多路预处理 → OCR → 投票统计"""
        all_results: list[str] = []

        if HAS_CV2:
            variants = self._preprocess_cv2(crop)
        else:
            variants = self._preprocess_pillow(crop)

        for variant_bytes in variants:
            try:
                all_results.append(self.ocr_beta.classification(variant_bytes))
                all_results.append(self.ocr_std.classification(variant_bytes))
            except Exception:
                continue

        # 归一化到单个中文字符：把 "理e" 这类混合结果保留为 "理"
        all_results = [self._normalize_ocr_char(r) for r in all_results]
        all_results = [r for r in all_results if r]
        vote_map = Counter(all_results)
        return set(all_results), dict(vote_map)

    @staticmethod
    def _is_cjk(s: str) -> bool:
        """检查字符串是否包含 CJK 字符（验证码目标字都是中文）"""
        return any('一' <= ch <= '鿿' for ch in s)

    @staticmethod
    def _normalize_ocr_char(s: str) -> str:
        """OCR 偶尔返回“理e”这类混合字符串，取第一个中文字符参与投票"""
        if not s:
            return ""
        for ch in s.strip():
            if '一' <= ch <= '鿿':
                return ch
        return ""

    # ---------- cv2 预处理流水线 ----------

    def _preprocess_cv2(self, crop: Image.Image) -> list[bytes]:
        """cv2 预处理：3 种最有效变体 × 3x 放大（兼顾速度与准确率）"""
        img_np = np.array(crop.convert("RGB"))
        gray = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY)
        variants: list[bytes] = []
        sw, sh = gray.shape[1] * 3, gray.shape[0] * 3

        scaled = cv2.resize(img_np, (sw, sh), interpolation=cv2.INTER_LANCZOS4)
        variants.append(self._cv2_to_bytes(scaled))

        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        clahe_scaled = cv2.resize(
            clahe.apply(gray), (sw, sh), interpolation=cv2.INTER_LANCZOS4)
        variants.append(self._cv2_to_bytes(clahe_scaled))

        _, otsu = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_scaled = cv2.resize(otsu, (sw, sh), interpolation=cv2.INTER_NEAREST)
        variants.append(self._cv2_to_bytes(otsu_scaled))

        return variants

    @staticmethod
    def _cv2_to_bytes(arr: "np.ndarray") -> bytes:
        """numpy 数组 → PNG bytes"""
        if len(arr.shape) == 2:  # 灰度
            mode = "L"
        elif arr.shape[2] == 3:
            arr = cv2.cvtColor(arr, cv2.COLOR_BGR2RGB)
            mode = "RGB"
        else:
            mode = "RGB"
        img = Image.fromarray(arr, mode=mode)
        buf = io.BytesIO(); img.save(buf, format="PNG"); buf.seek(0)
        return buf.read()

    # ---------- Pillow 兜底预处理 ----------

    def _preprocess_pillow(self, crop: Image.Image) -> list[bytes]:
        """Pillow 预处理（无 cv2 时使用）"""
        variants: list[bytes] = []

        for scale in (2, 3, 4):
            w, h = crop.size
            resized = crop.resize((w * scale, h * scale), Image.LANCZOS)

            # 原图
            buf = io.BytesIO(); resized.save(buf, format="PNG"); buf.seek(0)
            variants.append(buf.read())

            # 锐化
            sharp = resized.filter(ImageFilter.SHARPEN)
            buf = io.BytesIO(); sharp.save(buf, format="PNG"); buf.seek(0)
            variants.append(buf.read())

            # 灰度 + 对比度增强
            gray = resized.convert("L")
            enhanced = ImageEnhance.Contrast(gray).enhance(2.0)
            buf = io.BytesIO(); enhanced.save(buf, format="PNG"); buf.seek(0)
            variants.append(buf.read())

        return variants

    # ------------------------------------------------------------------
    # 置信度匹配
    # ------------------------------------------------------------------

    def _match_with_confidence(self, target_words: list[str],
                               candidates: list[dict]) -> list[dict] | None:
        """
        匹配策略（尽量凑满 4 个点击，把“刷新”降到最低）：
          1. 全局贪心：按票数把目标字分配到候选块（解决两个目标抢同一块）。
          2. 剩余没认出的目标，用排除法补到剩余候选块——优先补到识别置信度
             最低的块（最可能是 OCR 没认出的那个目标），把高置信但不在目标里
             的干扰字留着不点。
          3. 只要候选块数 >= 目标数，就总是返回完整 4 个点击顺序。
        刷新（走 get 接口）才是触发限流的主因，因此宁可按概率点击也不空刷。
        """
        n = len(target_words)
        if len(candidates) < n:
            return None

        # --- 全局贪心精确匹配 ---
        pairs = []  # (votes, target_index, cand_index)
        for ti, target in enumerate(target_words):
            for ci, c in enumerate(candidates):
                votes = c.get("vote_map", {}).get(target, 0)
                if votes > 0:
                    pairs.append((votes, ti, ci))
        pairs.sort(reverse=True)

        matched: dict[int, int] = {}      # target_index -> cand_index
        match_votes: dict[int, int] = {}
        used_t: set[int] = set()
        used_c: set[int] = set()
        for votes, ti, ci in pairs:
            if ti in used_t or ci in used_c:
                continue
            matched[ti] = ci
            match_votes[ti] = votes
            used_t.add(ti)
            used_c.add(ci)

        # --- 排除法补齐剩余目标 ---
        remaining_targets = [ti for ti in range(n) if ti not in used_t]
        # 剩余候选块按 best_votes 升序：置信度最低的最可能是没认出的目标
        remaining_cands = sorted(
            (ci for ci in range(len(candidates)) if ci not in used_c),
            key=lambda ci: candidates[ci].get("best_votes", 0),
        )
        for ti in remaining_targets:
            if not remaining_cands:
                return None  # 位置不够，无法凑满
            ci = remaining_cands.pop(0)
            matched[ti] = ci
            match_votes[ti] = 0

        # --- 按目标顺序输出点击坐标 ---
        result = []
        for ti, target in enumerate(target_words):
            c = candidates[matched[ti]]
            result.append({
                "char": target,
                "x": c["x"],
                "y": c["y"],
                "votes": match_votes.get(ti, 0),
            })

        confident = sum(1 for r in result if r["votes"] >= 2)
        guessed = [r["char"] for r in result if r["votes"] == 0]
        if guessed:
            log(f"    精确 {confident}/{n}，排除法猜测: {guessed}")
        return result

    # ------------------------------------------------------------------
    # 工具
    # ------------------------------------------------------------------

    @staticmethod
    def _decode_data_url(data_url: str) -> bytes | None:
        """解码 base64 data URL → 原始字节"""
        b64 = data_url
        for prefix in ("data:image/png;base64,", "data:image/jpeg;base64,"):
            if b64.startswith(prefix):
                b64 = b64[len(prefix):]
                break
        padding = 4 - len(b64) % 4
        if padding != 4:
            b64 += "=" * padding
        try:
            return base64.b64decode(b64)
        except Exception as e:
            log(f"  base64 解码失败: {e}")
            return None


# ---------- 主流程 ----------


def dismiss_dialog(page) -> str | None:
    """关闭可能存在的弹窗（验证失败、提示等），返回弹窗文字；无弹窗返回 None"""
    dialog_text = get_modal_text(page)

    # 优先点弹窗右上角 X
    try:
        close_x = page.locator(".ant-modal-wrap:visible .ant-modal-close")
        if close_x.count() > 0 and close_x.first.is_visible(timeout=300):
            close_x.first.click()
            human_wait(page, 500)
            text = dialog_text.strip()[:200]
            if text:
                log(f"    ⚠ 弹窗: {text}")
            return text
    except Exception:
        pass

    btn_names = ["关 闭", "确定", "OK"]
    for name in btn_names:
        try:
            btn = page.get_by_role("button", name=name)
            if btn.is_visible(timeout=500):
                if not dialog_text:
                    dialog_text = get_modal_text(page)
                btn.click()
                human_wait(page, 500)
                text = dialog_text.strip()[:200]
                if text:
                    log(f"    ⚠ 弹窗: {text}")
                return text
        except Exception:
            continue
    return None


def dismiss_all_dialogs(page, max_rounds=3) -> list[str]:
    """反复关闭弹窗直到没有弹窗为止，返回所有弹窗文字"""
    texts = []
    for _ in range(max_rounds):
        text = dismiss_dialog(page)
        if text is None:
            break
        texts.append(text)
    return texts


def has_visible_modal(page) -> bool:
    """是否存在遮挡操作的弹窗"""
    if get_modal_text(page):
        return True
    try:
        return page.locator(".ant-modal-wrap:visible").count() > 0
    except Exception:
        return False


def ensure_no_blocking_modal(page, timeout_sec: float = 3) -> list[str]:
    """等待并关闭遮挡验证码/查询的弹窗，返回收集到的弹窗文字"""
    collected = []
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if not has_visible_modal(page):
            break
        pending = get_modal_text(page)
        texts = dismiss_all_dialogs(page, max_rounds=5)
        if pending and pending not in collected:
            collected.append(pending)
        collected.extend(t for t in texts if t and t not in collected)
        if not has_visible_modal(page):
            break
        time.sleep(0.25)
    return collected


def is_captcha_rate_limited(*texts: str) -> bool:
    """是否触发验证码/接口频率限制"""
    combined = " ".join(t for t in texts if t)
    markers = ("失败数过多", "请求次数超限", "稍后再试")
    return any(m in combined for m in markers) or (
        "验证失败" in combined and "稍后再试" in combined)


def is_query_ip_limited(*texts: str) -> bool:
    """当前出口 IP 是否已达网站查询上限（需换 IP 后继续）"""
    combined = " ".join(t for t in texts if t)
    markers = ("查询受限", "明天再尝试", "明天再试", "请明日再试")
    return any(m in combined for m in markers)


def parse_captcha_targets(verify_msg: str) -> list[str] | None:
    """从「请顺序点击【字，字，字，字】」中解析 4 个目标字"""
    if "【" not in verify_msg or "】" not in verify_msg:
        return None
    inner = verify_msg.split("【", 1)[1].split("】", 1)[0]
    target_words = [w.strip() for w in inner.split("，") if w.strip()]
    return target_words if len(target_words) == 4 else None


def wait_for_captcha_targets(page, timeout_sec: float = 8) -> list[str] | str | None:
    """
    等待验证码提示加载完成。返回目标字列表、"rate_limited" 或 None。
    避免页面刚加载时 verify-msg 为空就直接判失败。
    """
    deadline = time.time() + timeout_sec
    last_msg = ""
    while time.time() < deadline:
        dialog_texts = ensure_no_blocking_modal(page, timeout_sec=1)
        if is_captcha_rate_limited(*dialog_texts):
            return "rate_limited"

        verify_msg = safe_text(page.locator("#checkCodeContainer .verify-msg"))
        if verify_msg and verify_msg != last_msg:
            log(f"  验证码: {verify_msg}")
            last_msg = verify_msg
        targets = parse_captcha_targets(verify_msg)
        if targets:
            return targets
        human_wait(page, 500)

    if last_msg:
        log(f"  无法解析目标字: {last_msg}")
    else:
        log("  验证码提示为空，等待超时")
    return None


def has_result_table(page) -> bool:
    """结果表是否已渲染（含「详 细」链接）"""
    try:
        result_table = page.locator("table")
        if result_table.count() > 0:
            return "详 细" in (result_table.first.text_content() or "")
    except Exception:
        pass
    return False


def get_modal_text(page) -> str:
    """读取当前可见弹窗文字（不关闭弹窗）"""
    try:
        modal = page.locator(".ant-modal-content")
        if modal.count() > 0 and modal.first.is_visible():
            return (modal.first.text_content() or "").strip()
    except Exception:
        pass
    return ""


def is_query_loading(page) -> bool:
    """查询请求是否仍在进行中"""
    try:
        if page.locator(".ant-spin:visible").count() > 0:
            return True
    except Exception:
        pass
    try:
        loading = page.get_by_text("加载中", exact=False)
        if loading.count() > 0 and loading.first.is_visible(timeout=200):
            return True
    except Exception:
        pass
    return False


def wait_for_query_result(page, timeout_sec: int = 30) -> str:
    """
    等待查询结束。返回:
      results         — 结果表已出现
      dialog          — 错误/提示弹窗已出现
      empty           — 加载结束但无结果、无弹窗
      loading_timeout — 超时后仍在加载
    """
    deadline = time.time() + timeout_sec
    seen_loading = False
    logged_wait = False

    while time.time() < deadline:
        if has_result_table(page):
            return "results"

        if get_modal_text(page):
            return "dialog"

        if is_query_loading(page):
            seen_loading = True
            if not logged_wait:
                log("    ⏳ 等待查询结果...")
                logged_wait = True
            time.sleep(0.5)
            continue

        human_wait(page, 800)
        if has_result_table(page):
            return "results"
        if get_modal_text(page):
            return "dialog"
        if is_query_loading(page):
            seen_loading = True
            continue
        return "empty"

    if seen_loading or is_query_loading(page):
        return "loading_timeout"
    return "empty"


def detail_links(page):
    """结果表中的「详细」链接"""
    return page.locator("table a").filter(has_text=re.compile(r"详\s*细"))


def wait_result_table_stable(page, timeout_sec: int = 8) -> bool:
    """等待结果表及「详细」链接可交互"""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if not has_result_table(page) or is_query_loading(page):
            time.sleep(0.3)
            continue
        links = detail_links(page)
        if links.count() > 0:
            try:
                if links.first.is_visible(timeout=500):
                    return True
            except Exception:
                pass
        time.sleep(0.3)
    return has_result_table(page)


def _read_locator_text(locator, timeout_ms: int = 2000) -> str:
    """短超时读取元素文本，避免抽屉动画期间 text_content 默认等 30 秒"""
    try:
        return (locator.text_content(timeout=timeout_ms) or "").strip()
    except Exception:
        return ""


def get_detail_panel(page):
    """返回内容已加载的详情面板 locator（抽屉或弹窗）"""
    selectors = [
        ".ant-drawer-open .ant-drawer-content-wrapper",
        ".ant-modal-wrap:visible .ant-modal-content",
    ]
    for sel in selectors:
        try:
            panel = page.locator(sel)
            if panel.count() == 0 or not panel.first.is_visible(timeout=300):
                continue
            text = _read_locator_text(panel.first)
            if "执业证书编码" in text:
                return panel.first
        except Exception:
            continue
    return None


def wait_for_detail_panel(page, timeout_sec: int = 20):
    """
    等待详情面板出现且内容加载完成。
    抽屉常有 2~6 秒动画，不能用短超时 + 默认 30 秒 text_content 混用。
    """
    drawer = page.locator(".ant-drawer-open")
    modal = page.locator(".ant-modal-wrap:visible .ant-modal-content")
    deadline = time.time() + timeout_sec

    # 先等容器出现（最多等到总超时）
    shell_deadline = min(deadline, time.time() + 8)
    while time.time() < shell_deadline:
        try:
            if drawer.count() > 0 and drawer.first.is_visible(timeout=300):
                break
            if modal.count() > 0 and modal.first.is_visible(timeout=300):
                break
        except Exception:
            pass
        time.sleep(0.3)

    while time.time() < deadline:
        panel = get_detail_panel(page)
        if panel is not None:
            return panel
        time.sleep(0.4)
    return None


def click_detail_link(page, index: int) -> bool:
    """滚动到可见并点击「详细」链接"""
    link = detail_links(page).nth(index)
    try:
        link.scroll_into_view_if_needed(timeout=5000)
    except Exception:
        pass
    human_wait(page, 300)

    for attempt in range(3):
        try:
            link.click(timeout=5000)
            return True
        except Exception:
            human_wait(page, 500)
            try:
                link = detail_links(page).nth(index)
            except Exception:
                pass

    try:
        link = detail_links(page).nth(index)
        link.click(force=True, timeout=3000)
        return True
    except Exception:
        return False


def open_detail_panel(page, index: int, max_attempts: int = 3):
    """点击「详细」并等待面板打开，失败时重试"""
    for attempt in range(1, max_attempts + 1):
        if attempt > 1:
            log(f"    🔄 [{index + 1}] 详情打开重试 {attempt}/{max_attempts}...")
            close_detail_panel(page)

        if not click_detail_link(page, index):
            continue

        panel = wait_for_detail_panel(page, timeout_sec=20)
        if panel is not None:
            human_wait(page, 400)
            return panel

        log(f"    [{index + 1}] 详情面板 {20}s 内未加载完成")
        human_wait(page, 800)

    return None


def close_detail_panel(page) -> bool:
    """关闭详情抽屉或弹窗，并等待遮罩消失"""
    candidates = [
        page.locator(".ant-drawer-open .ant-drawer-close"),
        page.locator(".ant-drawer-close"),
        page.locator(".ant-modal-close"),
        page.get_by_role("button", name="关 闭"),
        page.get_by_role("button", name=re.compile(r"关闭窗口")),
    ]
    closed = False
    for btn in candidates:
        try:
            if btn.count() > 0 and btn.first.is_visible(timeout=500):
                btn.first.click()
                human_wait(page, 500)
                closed = True
                break
        except Exception:
            continue

    # 等待抽屉/遮罩真正消失，避免重试时点到残留层
    deadline = time.time() + 3
    while time.time() < deadline:
        try:
            if page.locator(".ant-drawer-open").count() == 0:
                return closed or True
        except Exception:
            return closed
        time.sleep(0.2)
    return closed


def load_doctor_page(page):
    """打开医生查询页并关闭残留弹窗"""
    for attempt in range(1, 4):
        try:
            page.goto("https://zgcx.nhc.gov.cn/doctor",
                      wait_until="domcontentloaded", timeout=30000)
            break
        except Exception as e:
            if attempt >= 3:
                raise
            reason = str(e).splitlines()[0]
            log(f"  页面加载失败，{attempt}/3，稍后重试: {reason}")
            human_wait(page, 3000)
    human_wait(page, 2000)
    dismiss_all_dialogs(page)


def fill_query_form(page, name: str, province: str, hospital: str) -> list[str] | None:
    """填写查询表单，返回验证码目标字；失败返回 None"""
    try:
        province_combo = page.get_by_role("combobox", name="* 所在省份 :")
        province_combo.click()
        human_wait(page, 500)
        page.get_by_title(province).click()
        human_wait(page, 300)
        log(f"  省份: {province} ✓")
    except Exception as e:
        log(f"  选择省份失败: {e}")
        return None

    try:
        name_input = page.get_by_role("textbox", name="* 医师姓名 :")
        name_input.fill(name)
        log(f"  姓名: {name} ✓")
    except Exception as e:
        log(f"  填写姓名失败: {e}")
        return None

    try:
        hospital_input = page.get_by_role("textbox", name="* 所在医疗机构 :")
        hospital_input.fill(hospital)
        log(f"  机构: {hospital} ✓")
    except Exception as e:
        log(f"  填写机构失败: {e}")
        return None

    target_words = wait_for_captcha_targets(page)
    if isinstance(target_words, list):
        return target_words
    if target_words == "rate_limited":
        log("  验证码接口限流")
        return None
    return None


def wait_for_captcha_verdict(page, timeout_sec: float = 6) -> bool | str | None:
    """点击 4 个字后等待验证码结果，返回 True / False / "rate_limited" / None"""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        dialog_texts = ensure_no_blocking_modal(page, timeout_sec=1)
        if is_captcha_rate_limited(*dialog_texts):
            return "rate_limited"
        if any("验证失败" in text for text in dialog_texts):
            return False

        verify_msg = safe_text(page.locator("#checkCodeContainer .verify-msg"))
        if "验证成功" in verify_msg or "验证通过" in verify_msg:
            return True
        if "验证失败" in verify_msg:
            return False
        human_wait(page, 400)
    return None


def solve_and_click_captcha(page, solver, target_words, max_refresh=6) -> bool | str:
    """识别验证码并点击，失败时自动刷新重试"""
    canvas = page.locator("#checkCodeContainer canvas")
    refresh_btn = page.locator("#checkCodeContainer .icon-refresh").first

    for attempt in range(1, max_refresh + 1):
        dialog_texts = ensure_no_blocking_modal(page)
        if is_captcha_rate_limited(*dialog_texts):
            return "rate_limited"

        # 更新验证码提示（刷新后可能变），拿不到完整目标字则刷新而不是乱点
        current_targets = wait_for_captcha_targets(page, timeout_sec=5)
        if current_targets == "rate_limited":
            return "rate_limited"
        if not isinstance(current_targets, list):
            log(f"    [{attempt}/{max_refresh}] 验证码提示未就绪，刷新...")
            if not has_visible_modal(page):
                refresh_btn.click()
                human_wait(page, 1800)
            continue
        target_words = current_targets

        # 获取当前验证码图片
        canvas_data_url = canvas.evaluate("el => el.toDataURL('image/png')")
        click_order = solver.solve(canvas_data_url, target_words)

        if not click_order:
            log(f"    [{attempt}/{max_refresh}] 识别失败，刷新...")
            dialog_texts = ensure_no_blocking_modal(page)
            if is_captcha_rate_limited(*dialog_texts):
                return "rate_limited"
            if not has_visible_modal(page):
                refresh_btn.click()
                human_wait(page, 1800)
            continue

        log(f"    [{attempt}/{max_refresh}] 点击: {[(c['char'], c['x'], c['y']) for c in click_order]}")

        # 依次点击（force=True 绕过点击后出现的 point-area 标记点遮挡）
        for click_info in click_order:
            canvas.click(
                position={"x": click_info["x"], "y": click_info["y"]},
                force=True,
            )
            human_wait(page, 400)

        verdict = wait_for_captcha_verdict(page)
        if verdict is True:
            ensure_no_blocking_modal(page)
            return True
        if verdict == "rate_limited":
            return "rate_limited"
        if verdict is False:
            log(f"    [{attempt}/{max_refresh}] 验证失败")
            if attempt < max_refresh:
                if has_visible_modal(page):
                    log(f"    [{attempt}/{max_refresh}] 弹窗仍在，跳过验证码刷新")
                    continue
                refresh_btn.click()
                human_wait(page, 1800)
            continue

        log(f"    [{attempt}/{max_refresh}] 未返回验证结果，刷新...")
        if attempt < max_refresh and not has_visible_modal(page):
            refresh_btn.click()
            human_wait(page, 1800)

    return False


def run_captcha_pipeline(
    page, name: str, province: str, hospital: str, solver: CaptchaSolver,
) -> tuple[bool, str]:
    """
    完整验证码前置链路：加载页面 → 填表 → 破解验证码（不点查询）。
    返回 (成功与否, 失败说明)。
    """
    skip_next_page_load = False
    last_detail = "验证码破解失败"

    for query_attempt in range(2):
        if skip_next_page_load:
            skip_next_page_load = False
            dismiss_all_dialogs(page)
        else:
            load_doctor_page(page)

        target_words = fill_query_form(page, name, province, hospital)
        if target_words is None:
            modal = get_modal_text(page)
            if is_query_ip_limited(modal):
                return False, modal or "当前 IP 查询受限"
            return False, "填表失败"

        captcha_ok = False
        rate_limit_reloads = 0
        while True:
            captcha_result = solve_and_click_captcha(page, solver, target_words)
            if captcha_result is True:
                captcha_ok = True
                break
            if captcha_result == "rate_limited":
                rate_limit_reloads += 1
                last_detail = "验证失败次数过多"
                if rate_limit_reloads > 1:
                    break
                log("  ⚠ 验证失败次数过多，冷却 180 秒后刷新页面...")
                time.sleep(180)
                load_doctor_page(page)
                skip_next_page_load = True
                target_words = fill_query_form(page, name, province, hospital)
                if target_words is None:
                    modal = get_modal_text(page)
                    if is_query_ip_limited(modal):
                        return False, modal or "当前 IP 查询受限"
                    return False, "填表失败"
                continue
            break

        if captcha_ok:
            log("  验证码 ✓")
            return True, ""

        log("  验证码破解失败（已达最大重试次数）")
        if query_attempt == 0:
            if rate_limit_reloads == 0:
                log("  🔄 重新加载页面获取新验证码...")
                skip_next_page_load = False
            else:
                skip_next_page_load = True
            continue

    return False, last_detail


def query_one(page, name: str, province: str, hospital: str, solver: CaptchaSolver,
              known_cert_code: str | None = None,
              last_search_at: float = 0) -> tuple[int, float, bool]:
    """
    查询单个医生并截图所有结果。返回 (截图数量, 本次搜索点击时间戳, 是否 IP 查询上限)。
    known_cert_code: 已知的证书编码（来自 xlsx），用于精确命名和跳过已有截图
    last_search_at: 上次搜索点击的时间戳，用于控制查询间隔
    """
    log(f"--- 开始查询: {name} ---")

    has_results = False
    this_search_at = last_search_at

    # 外层重试：遇到网站冷却（间隔60秒）时重新加载页面重来
    for query_attempt in range(2):
        captcha_ok, captcha_detail = run_captcha_pipeline(
            page, name, province, hospital, solver)
        if not captcha_ok:
            if is_query_ip_limited(captcha_detail):
                log("  ⚠ 当前 IP 查询已达上限（验证码阶段）")
                return 0, last_search_at, True
            if query_attempt == 0:
                continue
            log_failure(name, "验证码破解失败")
            return 0, last_search_at, False

        # 7. 点击查询按钮（确保距上次搜索 ≥ 60 秒）
        ensure_no_blocking_modal(page)
        if last_search_at > 0:
            elapsed = time.time() - last_search_at
            if elapsed < 60:
                wait_s = 60 - elapsed + random.uniform(0.5, 1.0)
                log(f"    ⏳ 距上次查询 {elapsed:.0f}s，再等 {wait_s:.0f}s...")
                time.sleep(wait_s)
        search_btn = page.get_by_role("button", name="查 询")
        search_btn.click()
        this_search_at = time.time()

        outcome = wait_for_query_result(page)
        has_results = outcome == "results"

        if not has_results:
            if outcome == "loading_timeout":
                log("  查询超时：页面仍在加载中")
                if query_attempt == 0:
                    log("  🔄 重新加载页面重试...")
                    continue
                log_failure(name, "查询超时：页面仍在加载中")
                return 0, this_search_at, False

            dialog_text = get_modal_text(page) if outcome == "dialog" else ""
            if outcome == "dialog":
                dismiss_dialog(page)

            if is_query_ip_limited(dialog_text):
                reason = dialog_text[:200] if dialog_text else "当前 IP 查询受限"
                log(f"  ⚠ {reason}")
                return 0, last_search_at, True

            if "间隔" in dialog_text and "秒" in dialog_text:
                if query_attempt == 0:
                    log(f"    ⏳ 网站要求冷却，等待65秒后重试...")
                    time.sleep(65)
                    continue  # 回到步骤1，重新加载页面
                else:
                    log("  冷却后重试仍失败")
                    log_failure(name, "冷却后重试仍失败")
                    return 0, this_search_at, False
            elif outcome == "dialog":
                reason = dialog_text[:200] if dialog_text else "查询返回弹窗"
                log_failure(name, reason)
                return 0, this_search_at, False
            else:
                log_failure(name, "未找到任何结果")
                return 0, this_search_at, False

        if has_results:
            break  # 成功，跳出重试循环

    if not has_results:
        log_failure(name, "未找到任何结果")
        return 0, this_search_at, False

    # 8. 统计详情链接数量
    if not wait_result_table_stable(page):
        log("  结果表未就绪")
        log_failure(name, "结果表未就绪")
        return 0, this_search_at, False

    detail_link_loc = detail_links(page)
    total = detail_link_loc.count()
    if total == 0:
        log("  未找到详情链接")
        log_failure(name, "未找到详情链接")
        return 0, this_search_at, False
    log(f"  共 {total} 条结果，逐一截图...")

    # 9. 逐个点击详情并截图
    saved = 0
    for i in range(total):
        try:
            panel = open_detail_panel(page, i)
            if panel is None:
                raise PWTimeout("详情面板未在超时内打开")

            drawer_text = _read_locator_text(panel, timeout_ms=5000)
            if not drawer_text:
                panel = get_detail_panel(page)
                if panel is None:
                    raise PWTimeout("详情面板文本读取失败")
                drawer_text = _read_locator_text(panel, timeout_ms=5000)
            cert_code = extract_cert_code(drawer_text)
            if not cert_code:
                cert_code = f"unknown_{i + 1}"

            # 如果已知证书编码，只截图匹配的那一个
            save_cert = cert_code
            if known_cert_code:
                if cert_codes_match(cert_code, known_cert_code):
                    save_cert = known_cert_code
                elif cert_code.startswith("unknown_"):
                    if total == 1 or cert_code_in_text(known_cert_code, drawer_text):
                        log(f"  ⚠ [{i + 1}/{total}] 证书编码未解析，"
                            f"使用名单编码 {known_cert_code}")
                        save_cert = known_cert_code
                    else:
                        log(f"  ⏭ [{i + 1}/{total}] 跳过 {name}_{cert_code}"
                            f"（不匹配 {known_cert_code}）")
                        close_detail_panel(page)
                        continue
                else:
                    log(f"  ⏭ [{i + 1}/{total}] 跳过 {name}_{cert_code}"
                        f"（不匹配 {known_cert_code}）")
                    close_detail_panel(page)
                    continue

            # 截图命名：姓名_证书编码.png（跳过已存在的）
            filename = os.path.join(OUTPUT_DIR, f"{name}_{save_cert}.png")
            if os.path.exists(filename):
                log(f"  ⏭ [{i + 1}/{total}] {name}_{save_cert}（已存在）")
                saved += 1  # 算作已处理
                close_detail_panel(page)
                continue

            panel.screenshot(path=filename)
            log(f"  💾 [{i + 1}/{total}] {name}_{save_cert}")
            saved += 1
            close_detail_panel(page)
        except Exception as e:
            log(f"  ❌ [{i + 1}/{total}] 失败: {e}")
            close_detail_panel(page)

    log(f"--- {name} 查询完成: {saved}/{total} ---")
    return saved, this_search_at, False


def test_captcha_only(
    name: str,
    province: str = DEFAULT_PROVINCE,
    hospital: str = DEFAULT_HOSPITAL,
    rounds: int = 5,
    headless: bool = True,
    proxy: str | None = None,
    stealth: bool = True,
):
    """仅测试验证码前置链路（不点查询），统计通过率与耗时"""
    log(f"🧪 验证码专项测试: {name} × {rounds} 轮")
    solver = CaptchaSolver()
    stats = {"passed": 0, "failed": 0, "times": []}
    reasons: Counter = Counter()

    with sync_playwright() as pw:
        browser = launch_chromium(pw, headless, stealth)
        context_opts = {
            "viewport": {"width": 1280, "height": 900},
            "locale": "zh-CN",
        }
        if proxy:
            context_opts["proxy"] = {"server": proxy}
        context = browser.new_context(**context_opts)
        page = context.new_page()
        if stealth:
            Stealth().apply_stealth_sync(page)

        for i in range(rounds):
            log(f"=== 验证码测试 [{i + 1}/{rounds}] ===")
            t0 = time.time()
            try:
                ok, detail = run_captcha_pipeline(page, name, province, hospital, solver)
            except Exception as e:
                ok = False
                detail = f"异常: {str(e).splitlines()[0]}"
                # 失败后的页面状态可能不可用，重开一页让下一轮独立。
                try:
                    page.close()
                except Exception:
                    pass
                page = context.new_page()
                if stealth:
                    Stealth().apply_stealth_sync(page)
            elapsed = time.time() - t0
            stats["times"].append(elapsed)
            if ok:
                stats["passed"] += 1
                log(f"  ✅ 通过 ({elapsed:.1f}s)")
            else:
                stats["failed"] += 1
                reasons[detail or "未知"] += 1
                log(f"  ❌ 失败: {detail} ({elapsed:.1f}s)")
            if i < rounds - 1:
                time.sleep(2)

        browser.close()

    total = stats["passed"] + stats["failed"]
    avg = sum(stats["times"]) / len(stats["times"]) if stats["times"] else 0
    print("\n" + "=" * 50)
    if total:
        print(f"验证码测试完成: {stats['passed']}/{total} 通过 "
              f"({stats['passed'] / total * 100:.0f}%)")
    else:
        print("验证码测试完成: 无结果")
    print(f"平均耗时: {avg:.1f}s/轮")
    if reasons:
        print(f"失败原因: {dict(reasons)}")
    print("=" * 50)


def batch_query(
    doctors: list[dict],
    province: str = DEFAULT_PROVINCE,
    hospital: str = DEFAULT_HOSPITAL,
    interval: int = DEFAULT_INTERVAL,
    headless: bool = True,
    proxy: str | None = None,
    stealth: bool = True,
    clash_rotator: ClashRotator | None = None,
):
    """批量查询多个医生，doctors 为 [{"name": str, "certCode": str|None}, ...]"""
    ensure_output_dir()
    solver = CaptchaSolver()

    results = {"success": [], "failed": [], "total_screenshots": 0}

    with sync_playwright() as pw:
        browser = launch_chromium(pw, headless, stealth)

        context_opts = {
            "viewport": {"width": 1280, "height": 900},
            "locale": "zh-CN",
        }
        if proxy:
            context_opts["proxy"] = {"server": proxy}

        def new_page_ctx():
            ctx = browser.new_context(**context_opts)
            pg = ctx.new_page()
            if stealth:
                Stealth().apply_stealth_sync(pg)
            return ctx, pg

        context, page = new_page_ctx()
        last_search_at = 0.0
        doctor_idx = 0

        while doctor_idx < len(doctors):
            doc = doctors[doctor_idx]
            name = doc["name"].strip()
            cert_code = doc.get("certCode")
            if not name:
                doctor_idx += 1
                continue

            if doctor_idx > 0 and last_search_at > 0:
                elapsed = time.time() - last_search_at
                overhead = 12
                wait = max(0, interval - overhead - elapsed + random.uniform(0.5, 1.0))
                if wait > 0:
                    log(f"⏳ 网站冷却 {interval}s → 预留 {overhead}s 填表，已过 {elapsed:.0f}s，空闲等待 {wait:.0f}s...")
                    time.sleep(wait)

            ip_switch_attempts = 0
            max_ip_switch = clash_rotator.node_count if clash_rotator else 0
            done = False

            while not done:
                try:
                    saved, search_at, ip_limited = query_one(
                        page, name, province, hospital, solver, cert_code, last_search_at)

                    if ip_limited and clash_rotator and ip_switch_attempts < max_ip_switch:
                        node = clash_rotator.rotate()
                        if node:
                            ip_switch_attempts += 1
                            log(f"  🔁 换 IP 后重试: {name}（第 {ip_switch_attempts}/{max_ip_switch} 次）")
                            try:
                                page.close()
                            except Exception:
                                pass
                            try:
                                context.close()
                            except Exception:
                                pass
                            context, page = new_page_ctx()
                            last_search_at = 0
                            continue

                    if ip_limited:
                        log_failure(name, "当前 IP 查询受限，节点已轮换仍失败")
                        results["failed"].append(name)
                    elif saved > 0:
                        results["success"].append(name)
                        results["total_screenshots"] += saved
                    else:
                        results["failed"].append(name)

                    last_search_at = search_at if search_at > 0 else last_search_at
                    done = True
                except Exception as e:
                    log(f"  ❌ 异常: {e}")
                    log_failure(name, f"异常: {e}")
                    results["failed"].append(name)
                    done = True

            doctor_idx += 1

        try:
            page.close()
        except Exception:
            pass
        try:
            context.close()
        except Exception:
            pass
        browser.close()

    # 打印汇总
    print("\n" + "=" * 50)
    print(
        f"查询完成: 成功 {len(results['success'])} 人, "
        f"失败 {len(results['failed'])} 人, "
        f"共 {results['total_screenshots']} 张截图")
    if results["success"]:
        print(f"成功: {', '.join(results['success'])}")
    if results["failed"]:
        print(f"失败: {', '.join(results['failed'])}")
    print(f"截图保存在: {os.path.abspath(OUTPUT_DIR)}/")
    if results["failed"]:
        print(f"失败记录: {os.path.abspath(FAILURE_LOG)}")

    return results
