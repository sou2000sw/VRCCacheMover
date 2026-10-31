@echo off
rem VRC Cache Mover - double-click to start
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0VRCCacheMover.ps1" %*
if errorlevel 1 pause
