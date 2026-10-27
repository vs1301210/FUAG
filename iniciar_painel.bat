@echo off
chcp 65001 > nul
title FUAG - Ferramenta Universal de Acessibilidade em Games

:MENU
cls
echo ======================================================================
echo       🎮 FUAG - FERRAMENTA UNIVERSAL DE ACESSIBILIDADE EM GAMES
echo ======================================================================
echo.
echo [1] Iniciar Bridge em Segundo Plano (.EXE - System Tray / Toast)
echo [2] Iniciar Bridge com Interface Gráfica (.EXE --gui)
echo [3] Instalar Bridge Única no Windows (Iniciar com o Computador)
echo [4] Desinstalar Inicialização Automática com o Windows
echo [5] Executar App no Celular (Flutter Run - Modo Dev)
echo [6] Compilar Novo APK Debug (Flutter Build APK)
echo [7] Recompilar .EXE da Bridge (PyInstaller)
echo [8] Instalar APK no Celular via USB (ADB Install)
echo [9] Ativar Túnel USB ADB Reverso (Porta 5000)
echo [10] Instalar Driver Virtual Xbox/PS4 (ViGEmBus)
echo [11] Abrir Testador de Gamepads do Windows (joy.cpl)
echo [0] Sair
echo.
echo ========================================================
set /p OPT="Escolha uma opção (0-11): "

if "%OPT%"=="1" goto BRIDGE_BG
if "%OPT%"=="2" goto BRIDGE_GUI
if "%OPT%"=="3" goto BRIDGE_INSTALL
if "%OPT%"=="4" goto BRIDGE_UNINSTALL
if "%OPT%"=="5" goto FLUTTER_RUN
if "%OPT%"=="6" goto FLUTTER_BUILD
if "%OPT%"=="7" goto PYINSTALLER_BUILD
if "%OPT%"=="8" goto ADB_INSTALL
if "%OPT%"=="9" goto ADB_TUNNEL
if "%OPT%"=="10" goto VIGEM
if "%OPT%"=="11" goto JOY_CPL
if "%OPT%"=="0" goto SAIR
goto MENU

:BRIDGE_BG
cls
echo [*] Iniciando Mobile Controller Bridge em Segundo Plano (System Tray)...
start "" "%~dp0MobileControllerBridge.exe" --background
goto MENU

:BRIDGE_GUI
cls
echo [*] Iniciando Mobile Controller Bridge com Painel Visual...
start "" "%~dp0MobileControllerBridge.exe" --gui
goto MENU

:BRIDGE_INSTALL
cls
echo [*] Instalando Bridge Única e configurando para iniciar com o Windows...
"%~dp0MobileControllerBridge.exe" --install
echo.
pause
goto MENU

:BRIDGE_UNINSTALL
cls
echo [*] Removendo inicialização automática com o Windows...
"%~dp0MobileControllerBridge.exe" --uninstall
echo.
pause
goto MENU

:FLUTTER_RUN
cls
echo [*] Executando Flutter no celular conectado...
start "FUAG Flutter Runner" cmd /k "cd /d "%~dp0mobile_controller" && flutter run"
goto MENU

:FLUTTER_BUILD
cls
echo [*] Compilando APK Debug do Flutter...
cd /d "%~dp0mobile_controller"
call flutter build apk --debug
if %errorlevel% equ 0 (
    echo.
    echo [OK] APK compilado com sucesso!
    copy /y "%~dp0mobile_controller\build\app\outputs\flutter-apk\app-debug.apk" "%~dp0apks\app-debug.apk" > nul
    echo [OK] Cópia atualizada em %~dp0apks\app-debug.apk
) else (
    echo.
    echo [ERRO] Falha na compilação do APK.
)
echo.
pause
goto MENU

:PYINSTALLER_BUILD
cls
echo [*] Recompilando MobileControllerBridge.exe com PyInstaller...
cd /d "%~dp0"
call pyinstaller MobileControllerBridge.spec --noconfirm
if %errorlevel% equ 0 (
    copy /y "%~dp0dist\MobileControllerBridge.exe" "%~dp0MobileControllerBridge.exe" > nul
    copy /y "%~dp0dist\MobileControllerBridge.exe" "%LOCALAPPDATA%\FUAG\MobileControllerBridge.exe" > nul 2>&1
    echo.
    echo [OK] MobileControllerBridge.exe recompilado e atualizado com sucesso!
) else (
    echo.
    echo [ERRO] Falha na compilação do PyInstaller.
)
echo.
pause
goto MENU

:ADB_INSTALL
cls
echo [*] Instalando APK no dispositivo conectado via ADB...
set ADB_BIN="%~dp0tools\adb\adb.exe"
if not exist %ADB_BIN% set ADB_BIN=adb
%ADB_BIN% devices
echo.
%ADB_BIN% install -r "%~dp0apks\app-debug.apk"
echo.
pause
goto MENU

:ADB_TUNNEL
cls
echo [*] Ativando túnel USB ADB reverso (Porta 5000)...
set ADB_BIN="%~dp0tools\adb\adb.exe"
if not exist %ADB_BIN% set ADB_BIN=adb
%ADB_BIN% reverse tcp:5000 tcp:5000
echo.
pause
goto MENU

:VIGEM
cls
call "%~dp0install_driver.bat"
goto MENU

:JOY_CPL
cls
start joy.cpl
goto MENU

:SAIR
exit
