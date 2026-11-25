# Builds dist\Scribe (folder with Scribe.exe) and Scribe-Windows.zip.
# Run from the windows\ folder:  powershell -ExecutionPolicy Bypass -File packaging\build.ps1
$ErrorActionPreference = "Stop"
python packaging\make_icon.py
pyinstaller --noconfirm --clean --windowed --name Scribe `
  --icon packaging\Scribe.ico `
  --collect-all sherpa_onnx `
  --collect-submodules pynput `
  --collect-submodules pystray `
  --hidden-import pynput.keyboard._win32 `
  --hidden-import pynput.mouse._win32 `
  --hidden-import pystray._win32 `
  --add-data "NOTICE.txt;." `
  run_scribe.py
if ($LASTEXITCODE -ne 0) { throw "pyinstaller failed" }
Copy-Item README.txt, NOTICE.txt dist\Scribe\
if (Test-Path Scribe-Windows.zip) { Remove-Item Scribe-Windows.zip }
Compress-Archive -Path dist\Scribe -DestinationPath Scribe-Windows.zip
Get-Item Scribe-Windows.zip | Select-Object Name, Length
