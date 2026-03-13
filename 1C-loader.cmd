@echo off
start "" powershell.exe -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0scripts\Deploy-1C-Changes-GUI.ps1"
