@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键安装或更新.ps1" -Launch
if errorlevel 1 pause