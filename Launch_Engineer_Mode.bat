@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\HardwareValidator_GUI.ps1" -AppMode Engineer
if %errorlevel% neq 0 (
    echo.
    echo Hardware Validator exited with error code %errorlevel%.
    echo Check HardwareValidator_Error.log for details.
    pause
)
