@echo off
chcp 65001 > nul
title Mobile Controller Bridge
echo [*] Iniciando Mobile Controller Bridge em Segundo Plano (System Tray)...
start "" "%~dp0MobileControllerBridge.exe" --background
exit
