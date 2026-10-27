# 🎮 FUAG - Ferramenta Universal de Acessibilidade em Games
### *Suíte Universal de Controle Gamer por Visão Computacional, IA Local e Acessibilidade Severa*

[![Python Version](https://img.shields.io/badge/python-3.9%2B-blue.svg)](https://www.python.org/)
[![Flutter](https://img.shields.io/badge/flutter-3.0%2B-02569B.svg)](https://flutter.dev/)
[![MediaPipe](https://img.shields.io/badge/MediaPipe-Tasks%20Vision-FF6F00.svg)](https://developers.google.com/mediapipe)
[![ViGEmBus](https://img.shields.io/badge/Driver-ViGEmBus%201.17%2B-00B4D8.svg)](https://github.com/nefarius/ViGEmBus)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

O **FUAG** (*Ferramenta Universal de Acessibilidade em Games*) é uma solução de tecnologia assistiva e gamer que transforma câmeras comuns (webcams, sensores infravermelho Windows Hello e smartphones Android) em **dispositivos de entrada físicos reais** (Controle Oficial de Xbox 360, PlayStation 4 DualShock 4 e Teclado/Mouse DirectInput de ultra-baixa latência) para jogos de PC (Steam, Xbox Game Pass, Need for Speed, Counter-Strike, emuladores e simuladores), sem exigir nenhum hardware especializado caro.

---

## 🌟 Visão Geral da Arquitetura

O ecossistema FUAG é dividido em dois módulos complementares e independentes:

```
                              ┌─────────────────────────────────────────────────────────┐
                              │                    PC LOCAL CONTROLLER                  │
                              │                 (pc_local_controller.py)               │
                              │   Webcam / Câmera IR Windows Hello (Zero Latência)       │
                              └───────────────────────────┬─────────────────────────────┘
                                                          │
┌───────────────────────────┐         UDP / USB           ▼         ┌───────────────────────────┐
│     SMARTPHONE ANDROID    │─────────────────────────► BRIDGE ───► │      SISTEMA OPERACIONAL  │
│   (mobile_controller)     │  Túnel TCP ADB (Porta 5000)  (PC)     │   (Jogos, Steam, GamePass)│
│ Visão Computacional C++   │  Broadcast Wi-Fi Local                │  • Xbox 360 (XInput)      │
│ ML Kit & MediaPipe Zero-Cp│                                       │  • PS4 (DualShock 4)      │
└───────────────────────────┘                                       │  • Teclado/Mouse DirectIn │
                                                                    └───────────────────────────┘
```

1. **Módulo 1: PC Local Controller (`pc_local_controller.py`):**
   - **Autossuficiente para Desktop:** Não depende de celular, rede, Wi-Fi, ADB ou Sockets.
   - **Processamento 100% Local:** Processa a visão computacional diretamente no computador através da webcam ou sensor infravermelho (IR) com input lag próximo de zero.
   - **Interface Gráfica Completa (Tkinter Dark):** Seletor de modos, ajuste de sensibilidade, calibração de ângulo de volante, visualização do HUD em tempo real e injeção nos emuladores.

2. **Módulo 2: Mobile Controller Suite (`mobile_controller` + `mobile_controller_bridge.py`):**
   - **Aplicativo Mobile (Flutter + C++ Nativo):** Pipeline de câmera otimizado com *zero-copy* para leitura de quadros diretamente na GPU, descarte de quadros em caso de sobrecarga (frame dropping) e algoritmos biométricos nativos.
   - **Bridge de PC (Segundo Plano / System Tray):** Executa silenciosamente na barra de tarefas do Windows, gerenciando túneis USB automáticos (`adb reverse`), recebendo telemetria via UDP e traduzindo para os controles virtuais.

---

## 🕹️ Os 6 Modos de Controle Inteligente

### 1. 🏎️ Modo Gestual (Volante Gamer Virtual)
- **Ergonomia Natural:** Segure as mãos no ar na altura do peito, simulando a empunhadura de um volante real.
- **Centralização Temporal (Dwell Timer 0.3s):** Elimina a "zona morta rígida" artificial de simuladores convencionais. Se as mãos permanecerem na faixa guia central por 300ms, a entrada de esterçamento é imediatamente substituída por **CENTRO**, replicando o retorno realista de um volante de corrida real.
- **Aceleração e Freio por Polegares:**
  - **Polegar Direito Levantado (👍):** Aceleração contínua imediata (`W` ou gatilho `RT`).
  - **Polegar Esquerdo Levantado (👍):** Freio ou marcha à ré imediata (`S` ou gatilho `LT`).
  - **Exclusão Mútua:** Impede conflitos simultâneos de freio e aceleração por sombras ou ruído óptico.

### 2. 🎯 Modo FPS Mesh (Acessibilidade Severa / Hands-Free para CS 1.6)
Projetado especificamente para acessibilidade de jogadores com limitações motoras severas nos membros superiores:
- **Locomoção (WASD via Cabeça):**
  - O **Pitch** (inclinação vertical do nariz vs. centro dos olhos) e o **Yaw** (rotação horizontal da face) controlam o **Left Stick (Analógico Esquerdo / L-Stick)** do controle.
  - Centro neutro calibrado com deadzone de conforto para repouso estático do personagem.
- **Mira da Câmera (Mouse Analógico via Rastreamento Ocular):**
  - Extrai os *Facial Blendshapes* do MediaPipe (`eyeLookIn`, `eyeLookOut`, `eyeLookUp`, `eyeLookDown`).
  - Em vez de acumular deltas relativos de mouse (que causavam tremores por movimentos microssácadicos do olho), **os olhos emulam o Right Stick (Analógico Direito / R-Stick)** de um controle com controle de taxa (*rate-control*).
  - Olhar para o centro zera o analógico e fixa a mira instantaneamente sem drift; olhar para os cantos gira a câmera suavemente com aceleração exponencial ($y = (x / 0.4)^{1.3} \times \text{sensibilidade}$).
- **Gatilhos de Ação (Piscadas Intencionais):**
  - **Piscada Forte Esquerda (> 0.70):** Gatilho de Tiro (`RT` / `R2` / Botão Esquerdo do Mouse).
  - **Piscada Forte Direita (> 0.70):** Gatilho de Zoom/Mira (`LT` / `L2` / Botão Direito do Mouse).
  - **Piscada Dupla Apertada (> 0.85):** Recarregar Arma (Botão `X` no Xbox / `Quadrado` no PS4 / Tecla `R`).
  - **Sorriso / Abertura da Boca:** Pular (Botão `A` no Xbox / `Cruz` no PS4 / Barra de Espaço).

### 3. 🔫 Modo FPS (Gesto de Arma Manual / Hand Gun)
- **Cano da Arma (Dedo Indicador):** O nó 8 da mão funciona como um vetor de mira (*raycast*) na tela, com acumulador sub-pixel para precisão milimétrica.
- **Gatilho Mecânico (Dedo Médio):** O fechamento do dedo médio em direção à palma ativa o disparo do mouse (`M1`).
- **Mira Telescópica (Zoom):** A abdução do polegar voltado frontalmente para a câmera ativa a mira óptica (`M2`).
- **Recarga Tática:** Apoie ou afaste a segunda mão na base para acionar recarga rápida (`R`).

### 4. 🥊 Modo Luta (Brawler Corporal / Stick Fight)
- **Esquiva e Movimentação (A / D):** Inclinação do eixo do tronco (ombros vs. quadris).
- **Defesa (V):** Cruzamento dos antebraços em formato de "X" na frente do peito.
- **Ataque / Soco (C):** Extensão rápida e acelerada de qualquer um dos braços para frente.
- **Pulo Físico (W):** Elevação rápida do centro dos quadris.

### 5. 😀 Modo Facial (Controle por Expressões)
- **Direção:** Inclinação lateral da cabeça (*Roll*).
- **Aceleração / Ré:** Inclinação vertical da cabeça (*Pitch*).
- **Pulo / Ação:** Sorriso aberto ou abertura de boca (*Mouth Aspect Ratio*).

### 6. 🏃 Modo Corporal (Pose Completa)
- Rastreamento esquelético integral de 33 marcos anatômicos para jogos de plataforma e corrida.

---

## 🎮 Modos de Emulação de Saída no Windows

| Tradutor de Saída | Tecnologia | Aplicação | Compatibilidade |
| :--- | :--- | :--- | :--- |
| **Xbox 360 Controller** | XInput via ViGEmBus | Jogos modernos de PC | Steam, Game Pass, Epic, Forza, NFS, Emuladores |
| **PlayStation 4 Controller** | DualShock 4 via ViGEmBus | Simuladores e jogos PS | RPCS3, PCSX2, Steam com suporte a DS4 |
| **Teclado / Mouse Gamer** | Win32 DirectInput | Jogos clássicos e FPS | CS 1.6, emuladores retrô, jogos de navegador |

---

## 📁 Estrutura de Arquivos do Repositório

```
FUAG/
├── mobile_controller/            # Código-fonte completo do Aplicativo Flutter (Android)
│   ├── android/                  # Módulo nativo Android (Câmera, NDK, Permissões)
│   ├── lib/
│   │   ├── models/               # Modelos de dados e enumeração ControlMode
│   │   ├── screens/
│   │   │   ├── camera_screen.dart# Pipeline de visão, overlay HUD duplo e telemetria UDP
│   │   │   └── menu_screen.dart  # Interface do usuário, calibração e rede
│   │   └── services/
│   │       ├── udp_service.dart  # Cliente UDP/TCP com detecção de rede e túnel ADB
│   │       └── bluetooth_service.dart # Conexão RFCOMM/SPP sem fio
│   └── pubspec.yaml              # Dependências do Flutter (CameraX, ML Kit, MediaPipe)
├── tools/
│   ├── adb/                      # Utilitários ADB portáteis para Windows
│   └── ViGEmBusSetup_x64.msi     # Instalador oficial do driver virtual ViGEmBus
├── face_landmarker.task          # Modelo neural MediaPipe (478 pontos faciais + blendshapes)
├── hand_landmarker.task          # Modelo neural MediaPipe (21 marcos anatômicos por mão)
├── pose_landmarker_lite.task     # Modelo neural MediaPipe (33 marcos de corpo inteiro)
├── pc_local_controller.py        # Aplicação Desktop autossuficiente (Webcam/IR local)
├── mobile_controller_bridge.py   # Servidor Bridge de rede (UDP/TCP/ADB + System Tray)
├── requirements.txt              # Dependências Python para execução em qualquer computador
├── setup.sh                      # Script universal de instalação (Linux/macOS/Git Bash)
├── setup.bat                     # Script de instalação em 1 clique para Windows
├── iniciar_painel.bat            # Painel interativo completo em lote
├── iniciar_pc_controller.bat     # Atalho para o controlador local de PC
├── iniciar_bridge.bat            # Atalho para iniciar a Bridge em segundo plano
├── install_driver.bat            # Instalador com elevação UAC do driver ViGEmBus
├── .gitignore                    # Regras de exclusão limpas (sem logs, binários pesados ou dados pessoais)
└── README.md                     # Documentação técnica oficial (este arquivo)
```

---

## 🚀 Como Instalar e Rodar em Qualquer Computador

### 1. Clonar o Repositório
```bash
git clone https://github.com/SEU_USUARIO/FUAG.git
cd FUAG
```

### 2. Configurar o Ambiente

#### Opção A: No Linux, macOS ou Windows (Git Bash / WSL)
Execute o script automatizado:
```bash
chmod +x setup.sh
./setup.sh
```

#### Opção B: No Windows (Prompt de Comando ou PowerShell)
Basta dar duplo clique em `setup.bat` ou rodar no terminal:
```cmd
setup.bat
```

O script criará o ambiente virtual `venv`, instalará todas as bibliotecas de `requirements.txt`, verificará os modelos neurais do MediaPipe e baixará as dependências do Flutter se o SDK estiver instalado.

### 3. Instalar o Driver ViGEmBus (Obrigatório para Controles Xbox/PS4 no Windows)
Para que o Windows reconheça os controles virtuais:
- Execute `install_driver.bat` com permissão de Administrador; ou
- Abra diretamente `tools/ViGEmBusSetup_x64.msi` e conclua o assistente.

---

## 🎯 Executando os Módulos

### Modo 1: Jogar Diretamente no PC (Sem Celular)
Ideal para jogar usando a webcam do notebook ou computador:
```bash
python pc_local_controller.py
```
*Ou dê duplo clique em `iniciar_pc_controller.bat`.*

### Modo 2: Jogar Usando o Celular como Volante / Controle
1. Inicie a Bridge no computador:
   ```bash
   python mobile_controller_bridge.py --gui
   ```
2. Abra o aplicativo **FUAG** no smartphone.
3. **Conexão:**
   - **Cabo USB (Recomendado - Latência < 1ms):** Ative a "Depuração USB" no celular. A Bridge conecta automaticamente através de `adb reverse tcp:5000 tcp:5000`.
   - **Wi-Fi:** Conecte ambos na mesma rede. O app descobre a Bridge via broadcast UDP automaticamente.

### Modo 3: Painel Interativo de Atalhos (Windows)
Execute `iniciar_painel.bat` para acessar o menu com compilação, instalação de APK e testes em 1 clique.

---

## 🛠️ Compilando os Executáveis e o APK

### Compilar o APK Android (Flutter)
```bash
cd mobile_controller
flutter pub get
flutter build apk --debug
```
O arquivo gerado estará em `mobile_controller/build/app/outputs/flutter-apk/app-debug.apk`.

### Compilar o Executável Único Windows (`PCLocalController.exe`)
```bash
pyinstaller PCLocalController.spec --noconfirm
```

### Compilar o Executável da Bridge (`MobileControllerBridge.exe`)
```bash
pyinstaller MobileControllerBridge.spec --noconfirm
```

---

## 🔧 Solução de Problemas (Troubleshooting)

1. **"ViGEmBus Não Encontrado / Revertendo para Teclado":**
   - Certifique-se de ter instalado o driver através de `tools/ViGEmBusSetup_x64.msi`.
   - Abra o Executar (`Win + R`) e digite `joy.cpl`. Se o driver estiver ativo, ao selecionar Xbox ou PS4 no app, um novo dispositivo de jogo aparecerá instantaneamente na lista.
2. **Câmera Infravermelho (Windows Hello) não detectada:**
   - O `LocalVisionEngine` escaneia automaticamente os índices de câmera de 0 a 3 procurando sensores em escala de cinza. Se sua câmera IR exigir iluminação ativa, o fallback automático para a câmera RGB padrão (índice 0) é acionado.
3. **Celular não conecta via Wi-Fi:**
   - Verifique se a porta `5000` (UDP e TCP) está liberada no Firewall do Windows.
   - No menu do aplicativo móvel, toque em "Configurar IP" e insira manualmente o endereço IPv4 local do seu computador (obtido via `ipconfig`).

---

## 📄 Licença e Reconhecimentos

Este projeto é disponibilizado sob a licença **MIT**. Sinta-se livre para usar, modificar e distribuir.

- Desenvolvido com [Google MediaPipe](https://developers.google.com/mediapipe) e [Google ML Kit](https://developers.google.com/ml-kit).
- Emulação de gamepad impulsionada por [ViGEmBus](https://github.com/nefarius/ViGEmBus) e [vgamepad](https://github.com/yannbouteiller/vgamepad).
- Injeção de teclado DirectInput via [PyDirectInput](https://github.com/learncodebygaming/pydirectinput).
