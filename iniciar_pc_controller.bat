@echo off
chcp 65001 > nul
title FUAG PC Local Controller
if exist "%~dp0PCLocalController.exe" (
    start "" "%~dp0PCLocalController.exe"
) else (
    start "" python "%~dp0pc_local_controller.py"
)
exit
