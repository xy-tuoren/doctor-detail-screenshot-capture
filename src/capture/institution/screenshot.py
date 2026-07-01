"""Screenshot capture and hashing. Replaces PS1 bitmap functions."""

from __future__ import annotations

import hashlib
import io
import time
from typing import Optional

from PIL import Image, ImageGrab

from . import windows


def capture_window_bitmap(hwnd: int) -> Image.Image:
    """Bring window to front and capture its screen region."""
    windows.bring_to_front(hwnd)
    # Get current window rect via Win32 (more reliable than cached WindowInfo)
    from . import win32_api
    # Use uiautomation to get fresh rect
    import uiautomation as ua
    ctrl = ua.ControlFromHandle(hwnd)
    if ctrl is None:
        raise RuntimeError(f"Cannot get control for hwnd {hwnd}")
    rect = ctrl.BoundingRectangle
    left = max(0, rect.left)
    top = max(0, rect.top)
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    if width < 20 or height < 20:
        raise RuntimeError(f"Window rectangle too small: {width}x{height}")
    return ImageGrab.grab(bbox=(left, top, left + width, top + height))


def capture_screen_rect(left: int, top: int, width: int, height: int) -> Image.Image:
    return ImageGrab.grab(bbox=(left, top, left + width, top + height))


def get_bitmap_hash(image: Image.Image) -> str:
    """SHA256 hash of PNG bytes — for duplicate detection."""
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return hashlib.sha256(buf.getvalue()).hexdigest()


def get_screen_rect_hash(left: int, top: int, width: int, height: int) -> str:
    """SHA256 hash of a screen region — for stability detection."""
    img = capture_screen_rect(left, top, width, height)
    return get_bitmap_hash(img)


def wait_rect_stable(
    left: int, top: int, width: int, height: int,
    timeout_s: int = 10,
    stable_checks: int = 2,
) -> bool:
    """Wait until screen region stops changing (consecutive identical hashes)."""
    deadline = time.time() + timeout_s
    last_hash = ""
    same = 0
    while time.time() < deadline:
        try:
            h = get_screen_rect_hash(left, top, width, height)
            if h == last_hash:
                same += 1
            else:
                same = 0
                last_hash = h
            if same >= stable_checks:
                return True
        except Exception:
            pass
        time.sleep(0.7)
    return False
