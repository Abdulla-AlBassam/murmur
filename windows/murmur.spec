# PyInstaller spec for Murmur. Built by build.ps1, not run directly.
#
# collect_all is used liberally rather than hidden imports alone: every one
# of these packages ships native libraries or data files (PortAudio, the
# llama.cpp DLLs, CTranslate2, Whisper's voice-activity model) that
# PyInstaller's static analysis cannot see by itself. The build is larger
# for it and it works on a machine that has never seen Python.

from PyInstaller.utils.hooks import collect_all

datas, binaries, hiddenimports = [], [], []
for package in (
    "sounddevice",
    "soxr",
    "llama_cpp",
    "faster_whisper",
    "ctranslate2",
    "tokenizers",
    "onnxruntime",
    "av",
    "pystray",
    "PIL",
):
    package_datas, package_binaries, package_hidden = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hidden

hiddenimports += ["pystray._win32", "tkinter", "tkinter.ttk"]

analysis = Analysis(
    ["run_murmur.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    excludes=["matplotlib", "scipy", "pandas", "pytest", "torch"],
    noarchive=False,
)

pyz = PYZ(analysis.pure)

exe = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="Murmur",
    console=False,          # no console window on a normal launch
    icon="murmur.ico",
    version="version_info.txt",
)

COLLECT(
    exe,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,              # UPX makes antivirus far more suspicious
    name="Murmur",
)
