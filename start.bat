@echo off
REM Start Local STT - Windows launcher
REM Calls start.ps1 with appropriate execution policy

powershell -ExecutionPolicy Bypass -File "%~dp0start.ps1"
pause
