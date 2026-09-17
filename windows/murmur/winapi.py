"""Every call into Windows lives here: the push-to-talk hook, the paste, the
clipboard, the single-instance guard and the run-at-login entry.

The module imports cleanly on any platform so that the pipeline can be
tested off Windows; each function raises if it is actually called there.
"""

from __future__ import annotations

import ctypes
import sys
import threading
import time
from ctypes import wintypes
from dataclasses import dataclass

from .log import log

IS_WINDOWS = sys.platform == "win32"

if IS_WINDOWS:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    # ctypes assumes every undeclared function returns a C int. On 64-bit
    # Windows that silently truncates handles and pointers to their low 32
    # bits, which fails in ways that are very hard to read: a hook that
    # never fires, a clipboard write to an address that no longer exists.
    # Declaring the ones used here is not optional.
    LRESULT = ctypes.c_ssize_t
    LPVOID = ctypes.c_void_p

    user32.SetWindowsHookExW.restype = wintypes.HHOOK
    user32.SetWindowsHookExW.argtypes = [
        ctypes.c_int, LPVOID, wintypes.HINSTANCE, wintypes.DWORD
    ]
    user32.UnhookWindowsHookEx.restype = wintypes.BOOL
    user32.UnhookWindowsHookEx.argtypes = [wintypes.HHOOK]
    user32.CallNextHookEx.restype = LRESULT
    user32.CallNextHookEx.argtypes = [
        wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
    ]
    user32.SendInput.restype = wintypes.UINT
    user32.SendInput.argtypes = [wintypes.UINT, LPVOID, ctypes.c_int]
    user32.GetClipboardData.restype = wintypes.HANDLE
    user32.GetClipboardData.argtypes = [wintypes.UINT]
    user32.SetClipboardData.restype = wintypes.HANDLE
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.GetClipboardSequenceNumber.restype = wintypes.DWORD
    user32.FindWindowW.restype = wintypes.HWND
    user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.PostThreadMessageW.argtypes = [
        wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM
    ]

    kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalLock.restype = LPVOID
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalUnlock.restype = wintypes.BOOL
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalFree.restype = wintypes.HGLOBAL
    kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    kernel32.CreateMutexW.argtypes = [LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
    kernel32.GetCurrentThreadId.restype = wintypes.DWORD
else:  # importable for tests; nothing below is callable
    user32 = kernel32 = None


def _require_windows() -> None:
    if not IS_WINDOWS:
        raise RuntimeError("this is the Windows half of Murmur")


# MARK: - Push-to-talk key


@dataclass(frozen=True)
class Hotkey:
    key: str
    label: str
    vk: int
    #: True for keys whose normal effect should be swallowed while Murmur
    #: owns them. Caps Lock would otherwise toggle capitals every dictation.
    suppress: bool = False


#: Windows keyboards handle fn in firmware and never report it to software,
#: so the Mac build's key has no equivalent here. Right Ctrl is the closest
#: thing: present on every keyboard, does nothing on its own, and sits under
#: the right hand.
HOTKEYS: list[Hotkey] = [
    Hotkey("right_ctrl", "Right Ctrl", 0xA3),
    Hotkey("right_shift", "Right Shift", 0xA1),
    Hotkey("right_alt", "Right Alt", 0xA5),
    Hotkey("caps_lock", "Caps Lock", 0x14, suppress=True),
    Hotkey("scroll_lock", "Scroll Lock", 0x91, suppress=True),
    Hotkey("f9", "F9", 0x78),
    Hotkey("f10", "F10", 0x79),
]

HOTKEYS_BY_KEY = {hotkey.key: hotkey for hotkey in HOTKEYS}


def hotkey_for(key: str) -> Hotkey:
    return HOTKEYS_BY_KEY.get(key, HOTKEYS[0])


WH_KEYBOARD_LL = 13
WM_KEYDOWN, WM_KEYUP = 0x0100, 0x0101
WM_SYSKEYDOWN, WM_SYSKEYUP = 0x0104, 0x0105

#: Stamped on the keystrokes Murmur injects, so the hook can tell its own
#: paste apart from something the user pressed.
INJECTED_TAG = 0x4D524D52  # "MRMR"

if IS_WINDOWS:
    ULONG_PTR = ctypes.c_uint64 if ctypes.sizeof(ctypes.c_void_p) == 8 else ctypes.c_ulong

    class KBDLLHOOKSTRUCT(ctypes.Structure):
        _fields_ = [
            ("vkCode", wintypes.DWORD),
            ("scanCode", wintypes.DWORD),
            ("flags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ULONG_PTR),
        ]

    HOOKPROC = ctypes.WINFUNCTYPE(
        LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
    )


class HotkeyListener:
    """Watches one key globally with a low-level keyboard hook.

    The hook runs on its own thread with its own message pump, because
    Windows delivers low-level hook callbacks to the thread that installed
    the hook and gives that callback about 300 ms before deciding the hook
    is too slow and silently removing it. So the callback only flips a flag
    and hands the work to the caller's queue; nothing here blocks.

    Unlike the Mac's event tap, no permission grant is involved. The one
    thing the hook cannot see is a key pressed while a window running as
    administrator has focus, unless Murmur is elevated too.
    """

    def __init__(self, on_down, on_up) -> None:
        self.on_down = on_down
        self.on_up = on_up
        self._hotkey = HOTKEYS[0]
        self._down = False
        self._hook = None
        self._thread: threading.Thread | None = None
        self._thread_id = 0
        self._proc = None
        self._lock = threading.Lock()

    def set_hotkey(self, key: str) -> None:
        with self._lock:
            if self._down:
                # The key is changing mid-press; treat it as released so the
                # controller is not left waiting for an up that never comes.
                self._down = False
                self.on_up()
            self._hotkey = hotkey_for(key)
        log(f"push-to-talk key is {self._hotkey.label}")

    @property
    def hotkey(self) -> Hotkey:
        return self._hotkey

    def start(self) -> None:
        _require_windows()
        if self._thread:
            return
        self._thread = threading.Thread(target=self._pump, name="murmur-hook", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if IS_WINDOWS and self._thread_id:
            user32.PostThreadMessageW(self._thread_id, 0x0012, 0, 0)  # WM_QUIT

    def _pump(self) -> None:
        self._thread_id = kernel32.GetCurrentThreadId()
        self._proc = HOOKPROC(self._callback)
        self._hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._proc, None, 0)
        if not self._hook:
            log(f"could not install the keyboard hook: error {ctypes.get_last_error()}")
            return
        log("keyboard hook installed")
        message = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(message))
            user32.DispatchMessageW(ctypes.byref(message))
        user32.UnhookWindowsHookEx(self._hook)
        self._hook = None

    def _callback(self, code, wparam, lparam):
        if code < 0:
            return user32.CallNextHookEx(None, code, wparam, lparam)
        event = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        if event.dwExtraInfo == INJECTED_TAG:
            return user32.CallNextHookEx(None, code, wparam, lparam)

        with self._lock:
            hotkey = self._hotkey
            if event.vkCode != hotkey.vk:
                return user32.CallNextHookEx(None, code, wparam, lparam)

            is_down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)
            is_up = wparam in (WM_KEYUP, WM_SYSKEYUP)
            if not (is_down or is_up):
                return user32.CallNextHookEx(None, code, wparam, lparam)

            # Holding a key auto-repeats; only the transitions matter.
            changed = is_down != self._down
            if changed:
                self._down = is_down
                handler = self.on_down if is_down else self.on_up
            else:
                handler = None

        if handler is not None:
            try:
                handler()
            except Exception as error:  # never let a bad callback kill the hook
                log(f"hotkey handler failed: {error!r}")
        return 1 if hotkey.suppress else user32.CallNextHookEx(None, code, wparam, lparam)


# MARK: - Pasting


if IS_WINDOWS:

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [
            ("wVk", wintypes.WORD),
            ("wScan", wintypes.WORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ULONG_PTR),
        ]

    class _INPUTUNION(ctypes.Union):
        # MOUSEINPUT, the largest member, is 32 bytes on x64. Murmur never
        # sends one, but SendInput checks cbSize against the full union and
        # refuses anything smaller.
        _fields_ = [("ki", KEYBDINPUT), ("padding", ctypes.c_byte * 32)]

    class INPUT(ctypes.Structure):
        _anonymous_ = ("u",)
        _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
VK_CONTROL, VK_V = 0x11, 0x56


def _key_event(vk: int, up: bool):
    return INPUT(
        type=INPUT_KEYBOARD,
        ki=KEYBDINPUT(
            wVk=vk,
            wScan=0,
            dwFlags=KEYEVENTF_KEYUP if up else 0,
            time=0,
            dwExtraInfo=INJECTED_TAG,
        ),
    )


def send_ctrl_v() -> None:
    _require_windows()
    events = (INPUT * 4)(
        _key_event(VK_CONTROL, False),
        _key_event(VK_V, False),
        _key_event(VK_V, True),
        _key_event(VK_CONTROL, True),
    )
    sent = user32.SendInput(4, ctypes.byref(events), ctypes.sizeof(INPUT))
    if sent != 4:
        log(f"paste keystroke only partly delivered ({sent}/4)")


# MARK: - Clipboard

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002


def _open_clipboard(attempts: int = 10) -> bool:
    """Another app can hold the clipboard open; a short retry is normal."""
    for _ in range(attempts):
        if user32.OpenClipboard(None):
            return True
        time.sleep(0.02)
    return False


def clipboard_sequence() -> int:
    return int(user32.GetClipboardSequenceNumber()) if IS_WINDOWS else 0


def get_clipboard_text() -> str | None:
    _require_windows()
    if not _open_clipboard():
        return None
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return ctypes.wstring_at(pointer)
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def set_clipboard_text(text: str) -> bool:
    _require_windows()
    if not _open_clipboard():
        log("could not open the clipboard to paste")
        return False
    try:
        user32.EmptyClipboard()
        size = (len(text) + 1) * ctypes.sizeof(ctypes.c_wchar)
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        if not handle:
            return False
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            kernel32.GlobalFree(handle)
            return False
        ctypes.memmove(pointer, ctypes.create_unicode_buffer(text), size)
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(CF_UNICODETEXT, handle):
            kernel32.GlobalFree(handle)
            return False
        return True  # the system owns the handle now
    finally:
        user32.CloseClipboard()


# MARK: - One Murmur at a time

ERROR_ALREADY_EXISTS = 183
_mutex = None


def claim_single_instance(name: str = "Local\\MurmurSingleInstance") -> bool:
    """False when another Murmur is already running in this session.

    Two instances would both see the hotkey, both open the microphone and
    both paste, so the second to arrive brings the first forward and quits.
    """
    global _mutex
    if not IS_WINDOWS:
        return True
    _mutex = kernel32.CreateMutexW(None, True, name)
    if ctypes.get_last_error() == ERROR_ALREADY_EXISTS:
        return False
    return True


def bring_existing_window_forward(title: str = "Murmur") -> None:
    if not IS_WINDOWS:
        return
    handle = user32.FindWindowW(None, title)
    if handle:
        user32.ShowWindow(handle, 9)  # SW_RESTORE
        user32.SetForegroundWindow(handle)


# MARK: - Console


def attach_console() -> None:
    """Lets the windowed build print to the console that launched it.

    Murmur.exe is built without a console so that starting it normally does
    not flash a black window. That also means its output goes nowhere, which
    is no good for the diagnostic flags. Attaching to the parent console
    gives `Murmur.exe --diag` somewhere to write without a second binary.
    """
    if not IS_WINDOWS:
        return
    ATTACH_PARENT_PROCESS = -1
    if not kernel32.AttachConsole(ATTACH_PARENT_PROCESS):
        return
    try:
        sys.stdout = open("CONOUT$", "w", encoding="utf-8", buffering=1)
        sys.stderr = open("CONOUT$", "w", encoding="utf-8", buffering=1)
    except OSError:
        pass


# MARK: - Run at login

_RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
_RUN_VALUE = "Murmur"


def launch_command() -> str:
    """The command that starts this copy of Murmur again.

    Frozen, that is the exe. From a source checkout it is pythonw plus the
    package, so testing the toggle does not register a console window.
    """
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    interpreter = sys.executable.replace("python.exe", "pythonw.exe")
    return f'"{interpreter}" -m murmur'


def _startup_shortcut():
    """The installer offers to drop a shortcut in the Startup folder, which
    starts Murmur at sign-in without touching the registry. The checkbox in
    Settings has to account for it, or it will report "off" for a copy that
    plainly does start by itself."""
    import os
    from pathlib import Path

    appdata = os.environ.get("APPDATA")
    if not appdata:
        return None
    return Path(appdata) / "Microsoft/Windows/Start Menu/Programs/Startup/Murmur.lnk"


def get_launch_at_login() -> bool:
    if not IS_WINDOWS:
        return False
    import winreg

    shortcut = _startup_shortcut()
    if shortcut is not None and shortcut.exists():
        return True
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY) as key:
            winreg.QueryValueEx(key, _RUN_VALUE)
            return True
    except OSError:
        return False


def set_launch_at_login(enabled: bool) -> None:
    if not IS_WINDOWS:
        return
    import winreg

    # Turning it off has to clear both routes in, or it comes back.
    if not enabled:
        shortcut = _startup_shortcut()
        if shortcut is not None:
            try:
                shortcut.unlink(missing_ok=True)
            except OSError as error:
                log(f"could not remove the Startup shortcut: {error}")

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            if enabled:
                winreg.SetValueEx(key, _RUN_VALUE, 0, winreg.REG_SZ, launch_command())
            else:
                try:
                    winreg.DeleteValue(key, _RUN_VALUE)
                except FileNotFoundError:
                    pass
    except OSError as error:
        log(f"launch at login toggle failed: {error}")
