@echo off
chcp 65001 > nul
title FUAG - Ferramenta Universal de Acessibilidade em Games (Setup)

echo ======================================================================
echo   🎮 FUAG - FERRAMENTA UNIVERSAL DE ACESSIBILIDADE EM GAMES (SETUP)
echo ======================================================================
echo.

cd /d "%~dp0"

echo [*] Verificando Python...
python --version > nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] Python não foi encontrado no PATH do sistema.
    echo Por favor, instale o Python 3.9+ com a opção 'Add python.exe to PATH' marcada.
    pause
    exit /b 1
)

echo [*] Verificando / criando ambiente virtual (venv)...
if not exist "%~dp0venv" (
    python -m venv "%~dp0venv"
)

echo [*] Ativando ambiente virtual...
call "%~dp0venv\Scripts\activate.bat"

echo [*] Atualizando pip e instalando dependências...
python -m pip install --upgrade pip
pip install -r "%~dp0requirements.txt"

echo.
echo [*] Verificando modelos neurais MediaPipe...
if not exist "%~dp0face_landmarker.task" (
    echo [!] Baixando face_landmarker.task...
    powershell -Command "Invoke-WebRequest -Uri 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task' -OutFile '%~dp0face_landmarker.task'"
)
if not exist "%~dp0hand_landmarker.task" (
    echo [!] Baixando hand_landmarker.task...
    powershell -Command "Invoke-WebRequest -Uri 'https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task' -OutFile '%~dp0hand_landmarker.task'"
)
if not exist "%~dp0pose_landmarker_lite.task" (
    echo [!] Baixando pose_landmarker_lite.task...
    powershell -Command "Invoke-WebRequest -Uri 'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task' -OutFile '%~dp0pose_landmarker_lite.task'"
)

echo.
echo [*] Verificando Flutter...
flutter --version > nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Flutter detectado! Atualizando dependências mobile...
    cd /d "%~dp0mobile_controller"
    call flutter pub get
    cd /d "%~dp0"
) else (
    echo [AVISO] Flutter não encontrado no PATH (necessário apenas para compilar o APK mobile).
)

echo.
echo ======================================================================
echo          ✔ AMBIENTE CONFIGURADO COM SUCESSO!
echo ======================================================================
echo.
echo Para executar:
echo   - Controlador PC com Webcam/IR: iniciar_pc_controller.bat
echo   - Bridge com celular: iniciar_bridge.bat
echo   - Painel geral: iniciar_painel.bat
echo.
pause
