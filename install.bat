@echo off
chcp 65001 >nul
title Geely Cityray - ustanovka prilozheniy
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-all.ps1"
echo.
pause
