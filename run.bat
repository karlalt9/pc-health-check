@echo off
chcp 65001 >nul
title PC Health Check

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-health-check.ps1" %*

echo.
echo Press any key to close this window...
pause >nul
