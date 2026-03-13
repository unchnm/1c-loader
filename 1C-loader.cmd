@echo off
start "" powershell.exe -ExecutionPolicy Bypass -STA -NoProfile -WindowStyle Hidden -File "%~dp0scripts\Deploy-1C-Changes-GUI.ps1"
