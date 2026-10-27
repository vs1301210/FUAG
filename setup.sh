#!/usr/bin/env bash
# ==============================================================================
# FUAG - Script de Instalação e Configuração Automatizada
# Compatível com Linux, macOS e Windows (Git Bash / WSL / MSYS2)
# ==============================================================================

set -e

# Cores para formatação de saída no terminal
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_RED="\033[31m"

echo -e "${C_CYAN}${C_BOLD}"
echo "======================================================================"
echo "  🎮 FUAG - FERRAMENTA UNIVERSAL DE ACESSIBILIDADE EM GAMES (SETUP)   "
echo "======================================================================"
echo -e "${C_RESET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Detecção do Sistema Operacional
OS_TYPE="unknown"
case "$OSTYPE" in
  linux*)   OS_TYPE="linux" ;;
  darwin*)  OS_TYPE="macos" ;;
  msys*|cygwin*|win32*) OS_TYPE="windows" ;;
  *)        OS_TYPE="unknown" ;;
esac

echo -e "[*] Sistema Operacional Detectado: ${C_BOLD}${OS_TYPE}${C_RESET}"

# 2. Localização do Python 3 (3.9+)
PYTHON_BIN=""
if command -v python3 &>/dev/null; then
    PYTHON_BIN="python3"
elif command -v python &>/dev/null; then
    PYTHON_BIN="python"
else
    echo -e "${C_RED}[ERRO] Python 3 não foi encontrado no PATH do sistema.${C_RESET}"
    echo "Por favor, instale o Python 3.9 ou superior em: https://www.python.org/downloads/"
    exit 1
fi

PY_VERSION=$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "[*] Interpretador Python: ${C_BOLD}${PYTHON_BIN} (v${PY_VERSION})${C_RESET}"

# 3. Criação e Ativação do Ambiente Virtual (venv)
VENV_DIR="$SCRIPT_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo -e "[*] Criando ambiente virtual em: ${C_CYAN}$VENV_DIR${C_RESET}..."
    $PYTHON_BIN -m venv "$VENV_DIR"
fi

echo -e "[*] Ativando ambiente virtual..."
if [ -f "$VENV_DIR/bin/activate" ]; then
    # Linux / macOS
    source "$VENV_DIR/bin/activate"
elif [ -f "$VENV_DIR/Scripts/activate" ]; then
    # Windows (Git Bash / MSYS)
    source "$VENV_DIR/Scripts/activate"
fi

# 4. Instalação e Atualização das Dependências Python
echo -e "[*] Atualizando pip..."
pip install --upgrade pip

echo -e "[*] Instalando bibliotecas a partir de ${C_BOLD}requirements.txt${C_RESET}..."
pip install -r "$SCRIPT_DIR/requirements.txt"

# 5. Verificação e Download dos Modelos de Visão MediaPipe
echo -e "\n[*] Verificando modelos neurais do MediaPipe Tasks..."

download_model() {
    local file_name="$1"
    local download_url="$2"

    if [ ! -f "$SCRIPT_DIR/$file_name" ]; then
        echo -e "${C_YELLOW}[!] Modelo $file_name não encontrado. Baixando do repositório oficial...${C_RESET}"
        if command -v curl &>/dev/null; then
            curl -L -o "$SCRIPT_DIR/$file_name" "$download_url"
        elif command -v wget &>/dev/null; then
            wget -O "$SCRIPT_DIR/$file_name" "$download_url"
        else
            echo -e "${C_RED}[AVISO] curl ou wget não encontrados para baixar $file_name.${C_RESET}"
        fi
    else
        echo -e "${C_GREEN}[✔] Modelo $file_name já está presente.${C_RESET}"
    fi
}

download_model "face_landmarker.task" \
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task"

download_model "hand_landmarker.task" \
    "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"

download_model "pose_landmarker_lite.task" \
    "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"

# 6. Verificação do Flutter para o Aplicativo Mobile
echo -e "\n[*] Verificando SDK do Flutter..."
if command -v flutter &>/dev/null; then
    echo -e "${C_GREEN}[✔] Flutter detectado! Baixando dependências do aplicativo mobile...${C_RESET}"
    if [ -d "$SCRIPT_DIR/mobile_controller" ]; then
        cd "$SCRIPT_DIR/mobile_controller"
        flutter pub get
        cd "$SCRIPT_DIR"
        echo -e "${C_GREEN}[✔] Dependências do Flutter instaladas com sucesso!${C_RESET}"
    fi
else
    echo -e "${C_YELLOW}[AVISO] Flutter não está instalado ou não está no PATH.${C_RESET}"
    echo "        Se desejar compilar o app mobile (Android), instale o Flutter em: https://docs.flutter.dev/get-started/install"
fi

# 7. Instruções do Driver ViGEmBus (Exclusivo Windows)
if [ "$OS_TYPE" = "windows" ]; then
    echo -e "\n${C_CYAN}----------------------------------------------------------------------${C_RESET}"
    echo -e "${C_BOLD}🎮 DRIVER DE CONTROLES VIRTUAIS (VIGEMBUS):${C_RESET}"
    echo "Para emular controles oficiais de Xbox 360 e PS4 no Windows, instale o driver oficial:"
    echo -e "Execute: ${C_YELLOW}tools/ViGEmBusSetup_x64.msi${C_RESET} ou execute ${C_YELLOW}./install_driver.bat${C_RESET}"
    echo -e "${C_CYAN}----------------------------------------------------------------------${C_RESET}"
fi

echo -e "\n${C_GREEN}${C_BOLD}"
echo "======================================================================"
echo "          ✔ AMBIENTE CONFIGURADO COM SUCESSO!                         "
echo "======================================================================"
echo -e "${C_RESET}"
echo -e "Comandos para iniciar os módulos:"
echo -e "  1. Controlador Local PC (Webcam/IR): ${C_BOLD}python pc_local_controller.py${C_RESET}"
echo -e "  2. Bridge de Rede (Celular -> PC):    ${C_BOLD}python mobile_controller_bridge.py${C_RESET}"
echo -e "  3. Compilar APK do celular:           ${C_BOLD}cd mobile_controller && flutter build apk --debug${C_RESET}"
echo -e "  4. Menu Interativo (Windows):         ${C_BOLD}iniciar_painel.bat${C_RESET}\n"
