@echo off
rem Measure drive writes for 24 hours (author tool, not shipped). Results: measure\<start time>\
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Measure-VrcWrites.ps1" -Hours 24
pause
