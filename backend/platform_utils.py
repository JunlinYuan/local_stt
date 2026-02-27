"""Platform abstraction layer for cross-platform support.

Abstracts macOS-specific APIs (Quartz, objc, pbcopy, osascript) and provides
Windows equivalents (ctypes/win32, pyperclip, pyautogui).

All platform-specific code lives here. The rest of the codebase imports from
this module and never calls platform APIs directly.
"""

import subprocess
import sys
import webbrowser
from typing import Optional

# =============================================================================
# Platform detection
# =============================================================================

PLATFORM: str  # 'macos', 'windows', or 'linux'

if sys.platform == "darwin":
    PLATFORM = "macos"
elif sys.platform == "win32":
    PLATFORM = "windows"
else:
    PLATFORM = "linux"

IS_MACOS = PLATFORM == "macos"
IS_WINDOWS = PLATFORM == "windows"


# =============================================================================
# macOS-specific imports (lazy, guarded)
# =============================================================================

_quartz_loaded = False
_CGEventCreate = None
_CGEventGetLocation = None
_CGWindowListCopyWindowInfo = None
_kCGWindowListOptionOnScreenOnly = None
_kCGNullWindowID = None
_objc = None

if IS_MACOS:
    try:
        import objc as _objc
        from Quartz import (
            CGEventCreate as _CGEventCreate,
            CGEventGetLocation as _CGEventGetLocation,
            CGWindowListCopyWindowInfo as _CGWindowListCopyWindowInfo,
            kCGWindowListOptionOnScreenOnly as _kCGWindowListOptionOnScreenOnly,
            kCGNullWindowID as _kCGNullWindowID,
        )

        _quartz_loaded = True
    except ImportError:
        pass

# =============================================================================
# Windows-specific imports (lazy, guarded)
# =============================================================================

_win32_loaded = False

if IS_WINDOWS:
    try:
        import ctypes
        import ctypes.wintypes

        _win32_loaded = True
    except ImportError:
        pass


# =============================================================================
# Memory monitoring
# =============================================================================


def get_memory_mb() -> float:
    """Get current process memory usage in MB. Cross-platform."""
    if IS_WINDOWS:
        try:
            import psutil

            process = psutil.Process()
            return process.memory_info().rss / (1024 * 1024)
        except ImportError:
            # Fallback: use ctypes on Windows
            try:
                import ctypes
                from ctypes import wintypes

                class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
                    _fields_ = [
                        ("cb", wintypes.DWORD),
                        ("PageFaultCount", wintypes.DWORD),
                        ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t),
                        ("PeakPagefileUsage", ctypes.c_size_t),
                    ]

                counters = PROCESS_MEMORY_COUNTERS()
                counters.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
                kernel32 = ctypes.windll.kernel32
                handle = kernel32.GetCurrentProcess()
                psapi = ctypes.windll.psapi
                if psapi.GetProcessMemoryInfo(
                    handle, ctypes.byref(counters), counters.cb
                ):
                    return counters.WorkingSetSize / (1024 * 1024)
            except Exception:
                pass
            return 0.0
    else:
        # macOS / Linux
        try:
            import resource

            rusage = resource.getrusage(resource.RUSAGE_SELF)
            if sys.platform == "darwin":
                return rusage.ru_maxrss / (1024 * 1024)  # bytes to MB on macOS
            else:
                return rusage.ru_maxrss / 1024  # KB to MB on Linux
        except Exception:
            return 0.0


# =============================================================================
# Clipboard operations
# =============================================================================


def get_clipboard() -> Optional[str]:
    """Get current clipboard text content."""
    if IS_MACOS:
        try:
            result = subprocess.run(
                ["pbpaste"],
                capture_output=True,
                check=True,
            )
            return result.stdout.decode("utf-8")
        except subprocess.CalledProcessError:
            return None
    elif IS_WINDOWS:
        try:
            import pyperclip

            return pyperclip.paste()
        except ImportError:
            # Fallback: use PowerShell
            try:
                result = subprocess.run(
                    ["powershell", "-Command", "Get-Clipboard"],
                    capture_output=True,
                    check=True,
                    text=True,
                )
                return result.stdout.rstrip("\r\n")
            except Exception:
                return None
        except Exception:
            return None
    else:
        # Linux fallback
        try:
            import pyperclip

            return pyperclip.paste()
        except Exception:
            return None


def set_clipboard(text: str) -> bool:
    """Set clipboard text content."""
    if IS_MACOS:
        try:
            subprocess.run(
                ["pbcopy"],
                input=text.encode("utf-8"),
                check=True,
            )
            return True
        except subprocess.CalledProcessError:
            return False
    elif IS_WINDOWS:
        try:
            import pyperclip

            pyperclip.copy(text)
            return True
        except ImportError:
            # Fallback: use PowerShell
            try:
                # Escape single quotes for PowerShell string literals
                escaped = text.replace("'", "''")
                subprocess.run(
                    ["powershell", "-Command", f"Set-Clipboard -Value '{escaped}'"],
                    check=True,
                    capture_output=True,
                )
                return True
            except Exception:
                return False
        except Exception:
            return False
    else:
        try:
            import pyperclip

            pyperclip.copy(text)
            return True
        except Exception:
            return False


# =============================================================================
# Paste simulation
# =============================================================================


def simulate_paste(target_app: Optional[str] = None) -> bool:
    """Simulate paste keystroke (Cmd+V on macOS, Ctrl+V on Windows).

    Args:
        target_app: If provided on macOS, send paste to this specific app/process
                   without activating it. Ignored on Windows.
    """
    if IS_MACOS:
        try:
            if target_app:
                safe_name = target_app.replace("\\", "\\\\").replace('"', '\\"')
                script = f'''
                    tell application "System Events"
                        tell process "{safe_name}"
                            keystroke "v" using command down
                        end tell
                    end tell
                '''
            else:
                script = 'tell application "System Events" to keystroke "v" using command down'

            subprocess.run(
                ["osascript", "-e", script],
                check=True,
                capture_output=True,
                text=True,
            )
            return True
        except subprocess.CalledProcessError as e:
            print(f"Paste failed: {e.stderr.strip() if e.stderr else 'Unknown error'}")
            print(
                "   -> Grant Accessibility access: System Settings -> Privacy & Security -> Accessibility"
            )
            return False
    elif IS_WINDOWS:
        try:
            import pyautogui

            pyautogui.hotkey("ctrl", "v")
            return True
        except ImportError:
            # Fallback: use ctypes to send Ctrl+V
            try:
                import ctypes

                VK_CONTROL = 0x11
                VK_V = 0x56
                KEYEVENTF_KEYUP = 0x0002

                user32 = ctypes.windll.user32
                user32.keybd_event(VK_CONTROL, 0, 0, 0)
                user32.keybd_event(VK_V, 0, 0, 0)
                user32.keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0)
                user32.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
                return True
            except Exception:
                return False
        except Exception:
            return False
    else:
        # Linux: try xdotool
        try:
            subprocess.run(
                ["xdotool", "key", "ctrl+v"],
                check=True,
                capture_output=True,
            )
            return True
        except Exception:
            return False


# =============================================================================
# Mouse position
# =============================================================================


def get_mouse_position() -> tuple[float, float]:
    """Get current mouse cursor position as (x, y)."""
    if IS_MACOS and _quartz_loaded:
        event = _CGEventCreate(None)
        mouse = _CGEventGetLocation(event)
        return mouse.x, mouse.y
    elif IS_WINDOWS:
        try:
            import pyautogui

            pos = pyautogui.position()
            return float(pos[0]), float(pos[1])
        except ImportError:
            # Fallback: ctypes
            try:
                import ctypes

                class POINT(ctypes.Structure):
                    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

                pt = POINT()
                ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
                return float(pt.x), float(pt.y)
            except Exception:
                return 0.0, 0.0
        except Exception:
            return 0.0, 0.0
    else:
        # Linux fallback
        try:
            import pyautogui

            pos = pyautogui.position()
            return float(pos[0]), float(pos[1])
        except Exception:
            return 0.0, 0.0


# =============================================================================
# Window detection under mouse
# =============================================================================


def get_app_at_position(mouse_x: float, mouse_y: float) -> Optional[str]:
    """Find which app owns the window at the given screen position.

    Returns the app/process name, or None if detection fails.
    """
    if IS_MACOS and _quartz_loaded:
        with _objc.autorelease_pool():
            try:
                windows = _CGWindowListCopyWindowInfo(
                    _kCGWindowListOptionOnScreenOnly, _kCGNullWindowID
                )
                for win in windows:
                    bounds = win.get("kCGWindowBounds", {})
                    x = bounds.get("X", 0)
                    y = bounds.get("Y", 0)
                    w = bounds.get("Width", 0)
                    h = bounds.get("Height", 0)
                    owner = win.get("kCGWindowOwnerName", "")
                    layer = win.get("kCGWindowLayer", 0)

                    if layer != 0:
                        continue

                    if x <= mouse_x <= x + w and y <= mouse_y <= y + h:
                        return owner
                return None
            except Exception:
                return None
    elif IS_WINDOWS and _win32_loaded:
        try:
            # WindowFromPoint takes POINT by value — must set argtypes
            user32 = ctypes.windll.user32
            user32.WindowFromPoint.argtypes = [ctypes.wintypes.POINT]
            user32.WindowFromPoint.restype = ctypes.wintypes.HWND
            point = ctypes.wintypes.POINT(int(mouse_x), int(mouse_y))
            hwnd = user32.WindowFromPoint(point)
            if not hwnd:
                return None

            # Walk up to the top-level (owner) window
            GA_ROOT = 2
            root_hwnd = ctypes.windll.user32.GetAncestor(hwnd, GA_ROOT)
            if root_hwnd:
                hwnd = root_hwnd

            # Get window title
            length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
            if length > 0:
                buf = ctypes.create_unicode_buffer(length + 1)
                ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
                return buf.value if buf.value else None

            # Fallback: get process name
            pid = ctypes.wintypes.DWORD()
            ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value:
                try:
                    import psutil

                    proc = psutil.Process(pid.value)
                    return proc.name()
                except Exception:
                    pass

            return None
        except Exception:
            return None
    else:
        return None


# =============================================================================
# Focus / activate app
# =============================================================================


def focus_app(app_name: str) -> bool:
    """Bring the named app to focus (activate it).

    On macOS, uses AppleScript. On Windows, uses SetForegroundWindow via ctypes.
    """
    if IS_MACOS:
        try:
            safe_name = app_name.replace("\\", "\\\\").replace('"', '\\"')
            subprocess.run(
                ["osascript", "-e", f'tell application "{safe_name}" to activate'],
                capture_output=True,
                timeout=0.3,
            )
            return True
        except subprocess.TimeoutExpired:
            return False
        except Exception:
            return False
    elif IS_WINDOWS and _win32_loaded:
        try:
            # Find window by title
            target_hwnd = None

            EnumWindowsProc = ctypes.WINFUNCTYPE(
                ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM
            )

            def callback(hwnd, _lparam):
                nonlocal target_hwnd
                if not ctypes.windll.user32.IsWindowVisible(hwnd):
                    return True
                length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
                if length <= 0:
                    return True
                buf = ctypes.create_unicode_buffer(length + 1)
                ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
                if app_name.lower() in buf.value.lower():
                    target_hwnd = hwnd
                    return False  # Stop enumeration
                return True

            ctypes.windll.user32.EnumWindows(EnumWindowsProc(callback), 0)

            if target_hwnd:
                ctypes.windll.user32.SetForegroundWindow(target_hwnd)
                return True
            return False
        except Exception:
            return False
    else:
        return False


# =============================================================================
# Browser
# =============================================================================


def open_browser(url: str) -> None:
    """Open a URL in the default browser."""
    webbrowser.open(url)


# =============================================================================
# Keybinding helpers
# =============================================================================


def get_modifier_key_name() -> str:
    """Get the platform-appropriate name for the secondary modifier key.

    macOS: 'Command' / 'Option'
    Windows: 'Alt'
    """
    if IS_MACOS:
        return "Command"
    else:
        return "Alt"


def get_keybinding_display(keybinding: str) -> str:
    """Get human-readable keybinding string for the current platform."""
    if IS_MACOS:
        return {
            "ctrl_only": "Left Ctrl",
            "ctrl": "Left Ctrl + Left Command",
            "shift": "Left Shift + Left Command",
        }.get(keybinding, keybinding)
    else:
        # Windows/Linux: use Alt instead of Command
        return {
            "ctrl_only": "Left Ctrl",
            "ctrl": "Left Ctrl + Left Alt",
            "shift": "Left Shift + Left Alt",
        }.get(keybinding, keybinding)


def get_paste_shortcut_display() -> str:
    """Get the platform paste shortcut for display."""
    if IS_MACOS:
        return "Cmd+V"
    else:
        return "Ctrl+V"
