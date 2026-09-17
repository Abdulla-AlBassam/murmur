<#
    Builds Murmur into dist\MurmurSetup-<version>.exe.

    Run this on a Windows 11 PC with Python 3.12 (python.org, "Add to PATH"
    ticked) and Inno Setup 6 installed. Everything else it fetches itself.

        powershell -ExecutionPolicy Bypass -File build.ps1

    Add -IncludeModels to bake the speech and polishing models into the
    installer. That turns a ~400 MB download into a ~3.5 GB one, and in
    exchange the PC it is installed on never has to download anything. Worth
    it when the machine you are sending it to has a slow connection.
#>
param(
    [switch]$IncludeModels,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
Set-Location $root
$version = "0.1.0"

function Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

# ---------------------------------------------------------------- environment

Step "Checking Python"
$python = (Get-Command py -ErrorAction SilentlyContinue)
if ($python) { $py = "py -3.12" } else { $py = "python" }
& cmd /c "$py --version" | Write-Host

Step "Creating the build environment"
if (-not (Test-Path "$root\.venv")) { & cmd /c "$py -m venv `"$root\.venv`"" }
$venvPython = "$root\.venv\Scripts\python.exe"

Step "Installing dependencies"
& $venvPython -m pip install --upgrade pip --quiet
& $venvPython -m pip install --quiet -r requirements.txt `
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu
& $venvPython -m pip install --quiet pyinstaller

Step "Checking that llama.cpp loaded"
& $venvPython -c "import llama_cpp, faster_whisper, sounddevice; print('all three imported')"
if ($LASTEXITCODE -ne 0) { throw "a dependency failed to import; the build would ship broken" }

# --------------------------------------------------------------------- assets

Step "Drawing the icon"
& $venvPython -c "import sys; sys.path.insert(0, '.'); from murmur.ui import save_ico; save_ico('murmur.ico')"

@"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=(0, 1, 0, 0), prodvers=(0, 1, 0, 0), mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0),
  kids=[
    StringFileInfo([StringTable('040904B0', [
      StringStruct('CompanyName', 'Abdulla AlBassam'),
      StringStruct('FileDescription', 'Murmur push-to-talk dictation'),
      StringStruct('FileVersion', '$version'),
      StringStruct('InternalName', 'Murmur'),
      StringStruct('OriginalFilename', 'Murmur.exe'),
      StringStruct('ProductName', 'Murmur'),
      StringStruct('ProductVersion', '$version')])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
"@ | Set-Content -Encoding UTF8 "$root\version_info.txt"

# ---------------------------------------------------------------------- build

Step "Running the tests"
& $venvPython -m pip install --quiet pytest
& $venvPython -m pytest tests -q
if ($LASTEXITCODE -ne 0) { throw "tests failed; not building" }

Step "Freezing the app"
Remove-Item -Recurse -Force "$root\build", "$root\dist\Murmur" -ErrorAction SilentlyContinue
& $venvPython -m PyInstaller --noconfirm --clean murmur.spec
if (-not (Test-Path "$root\dist\Murmur\Murmur.exe")) { throw "PyInstaller did not produce Murmur.exe" }

Step "Smoke-testing the frozen build"
& "$root\dist\Murmur\Murmur.exe" --diag | Write-Host

# --------------------------------------------------------------------- models

if ($IncludeModels) {
    Step "Fetching the models to bundle"
    & $venvPython -c @"
import sys; sys.path.insert(0, '.')
from murmur import polish, paths
from murmur.store import Settings
paths.ensure_directories()
choice = polish.resolve_choice(Settings().polish_model)
polish.download(choice, lambda d, t: print(f'\r  {d/t:6.1%}', end=''))
print()
from faster_whisper import WhisperModel
WhisperModel(Settings().whisper_model, device='cpu', compute_type='int8', download_root=str(paths.MODELS_DIR))
print('models ready in', paths.MODELS_DIR)
"@
    $modelsDir = & $venvPython -c "import sys; sys.path.insert(0,'.'); from murmur import paths; print(paths.MODELS_DIR)"
    New-Item -ItemType Directory -Force -Path "$root\dist\bundled-models" | Out-Null
    Copy-Item -Recurse -Force "$modelsDir\*" "$root\dist\bundled-models\"
}

# ------------------------------------------------------------------ installer

if ($SkipInstaller) {
    Step "Done (installer skipped). The app is in dist\Murmur."
    exit 0
}

Step "Building the installer"
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found. Install it from https://jrsoftware.org/isdl.php" }

$flags = @("/DMyAppVersion=$version")
if ($IncludeModels) { $flags += "/DIncludeModels" }
& $iscc @flags "installer.iss"

Step "Done"
Get-ChildItem "$root\dist\*.exe" | ForEach-Object {
    "{0}  ({1:N0} MB)" -f $_.Name, ($_.Length / 1MB) | Write-Host -ForegroundColor Green
}
Write-Host "`nSend that one file. Nothing else is needed." -ForegroundColor Green
