"""
Mobile Controller Bridge - Universal Windows Gamepad & Input Emulator
====================================================================
Recebe telemetria e comandos do aplicativo móvel (via USB ADB Reverse ou Wi-Fi)
e injeta diretamente no Windows como:
1. Controle Xbox 360 (Virtual XInput Gamepad via ViGEmBus)
2. Controle PlayStation 4 (DualShock 4 via ViGEmBus)
3. Teclado DirectInput (WASD / Setas / Espaço via SendInput/pydirectinput)

Permite jogar qualquer jogo de PC (Steam, Game Pass, Emuladores, Navegador, etc.)
usando o smartphone como volante e controle interativo!
"""

import sys
import os
import time
import json
import socket
import select
import threading
import subprocess
import shutil
import ctypes
from typing import Optional, Dict, Any

# Garante suporte a UTF-8 e flush imediato no console do Windows
if sys.stdout and hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace', line_buffering=True)
        sys.stderr.reconfigure(encoding='utf-8', errors='replace', line_buffering=True)
    except Exception:
        pass

# Desativa failsafe e pausas do pydirectinput globalmente
try:
    import pydirectinput
    pydirectinput.FAILSAFE = False
    pydirectinput.PAUSE = 0.0
except Exception:
    pass

# Helper de anexo ao desktop interativo do usuário do Windows
_attached_threads = set()
_attach_lock = threading.Lock()

def attach_thread_to_input_desktop(force: bool = False) -> bool:
    """Garante que a thread chamadora esteja anexada ao desktop de entrada interativo do usuário.
    Fundamental para que o Windows aceite injeção de mouse/teclado de processos e threads em segundo plano
    sem retornar ERROR_ACCESS_DENIED (5). Faz cache por thread para máxima performance."""
    tid = threading.get_ident()
    if not force:
        with _attach_lock:
            if tid in _attached_threads:
                return True
    try:
        user32 = ctypes.windll.user32
        hdesk = user32.OpenInputDesktop(0, False, 0x01FF)
        if hdesk:
            ok = user32.SetThreadDesktop(hdesk)
            user32.CloseDesktop(hdesk)
            if ok:
                with _attach_lock:
                    _attached_threads.add(tid)
                return True
    except Exception:
        pass
    return False

# Constantes Win32 e funções de injeção nativa de alta velocidade e precisão
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
KEYEVENTF_KEYUP = 0x0002
VK_R = 0x52
SCAN_R = 0x13

def win32_mouse_move(dx: int, dy: int):
    if dx != 0 or dy != 0:
        attach_thread_to_input_desktop()
        ctypes.windll.user32.mouse_event(MOUSEEVENTF_MOVE, int(dx), int(dy), 0, 0)

def win32_mouse_button(button: str, down: bool):
    attach_thread_to_input_desktop()
    if button == "left":
        flags = MOUSEEVENTF_LEFTDOWN if down else MOUSEEVENTF_LEFTUP
    elif button == "right":
        flags = MOUSEEVENTF_RIGHTDOWN if down else MOUSEEVENTF_RIGHTUP
    else:
        return
    ctypes.windll.user32.mouse_event(flags, 0, 0, 0, 0)

def win32_press_reload():
    attach_thread_to_input_desktop()
    ctypes.windll.user32.keybd_event(VK_R, SCAN_R, 0, 0)
    def _up():
        attach_thread_to_input_desktop()
        ctypes.windll.user32.keybd_event(VK_R, SCAN_R, KEYEVENTF_KEYUP, 0)
    threading.Timer(0.08, _up).start()

# ==============================================================================
# 1. UTILITÁRIOS DE AMBIENTE E DRIVERS
# ==============================================================================

def get_base_path() -> str:
    """Retorna o diretório base da aplicação (suporta PyInstaller)."""
    if getattr(sys, 'frozen', False) and hasattr(sys, '_MEIPASS'):
        return sys._MEIPASS
    return os.path.dirname(os.path.abspath(__file__))

def get_adb_path() -> Optional[str]:
    """Localiza o binário adb.exe embutido, na pasta tools ou no sistema."""
    base = get_base_path()
    
    # 1. Embutido no PyInstaller
    embedded = os.path.join(base, "adb.exe")
    if os.path.exists(embedded):
        return embedded

    # 2. Na pasta tools/adb relativa ao executável ou script
    app_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    local_tool = os.path.join(app_dir, "tools", "adb", "adb.exe")
    if os.path.exists(local_tool):
        return local_tool
        
    local_tool_rel = os.path.join(base, "tools", "adb", "adb.exe")
    if os.path.exists(local_tool_rel):
        return local_tool_rel

    # 3. No PATH do sistema
    which_adb = shutil.which("adb")
    if which_adb and os.path.exists(which_adb):
        return which_adb

    # 4. No caminho padrão do Android SDK no Windows
    sdk_adb = os.path.expanduser(r"~\AppData\Local\Android\Sdk\platform-tools\adb.exe")
    if os.path.exists(sdk_adb):
        return sdk_adb

    return None

def get_vigem_msi_path() -> Optional[str]:
    """Localiza o instalador ViGEmBusSetup_x64.msi."""
    base = get_base_path()
    candidates = [
        os.path.join(base, "ViGEmBusSetup_x64.msi"),
        os.path.join(base, "tools", "ViGEmBusSetup_x64.msi"),
        os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "tools", "ViGEmBusSetup_x64.msi"),
        os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "ViGEmBusSetup_x64.msi"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None

def check_vigem_driver() -> bool:
    """Verifica se o driver do ViGEmBus está instalado e funcional no Windows."""
    # 1. Teste nativo e infalível via vgamepad (alocação do bus virtual)
    try:
        import vgamepad
        bus = vgamepad.win.virtual_gamepad.VBus()
        del bus
        return True
    except Exception:
        pass

    # 2. Verificação direta no registro de serviços do Windows (Nefarius ViGEmBus)
    try:
        import winreg
        service_key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Services\ViGEmBus")
        winreg.CloseKey(service_key)
        return True
    except Exception:
        pass

    # 3. Verificação no registro de programas instalados
    try:
        import winreg
        uninstall_paths = [
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{96E42B22-F5E9-42F8-B043-ED0F932F014F}",
            r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{96E42B22-F5E9-42F8-B043-ED0F932F014F}",
            r"SOFTWARE\Nefarius Software Solutions e.U.\ViGEm Bus Driver",
        ]
        for p in uninstall_paths:
            try:
                k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, p)
                winreg.CloseKey(k)
                return True
            except OSError:
                pass
    except Exception:
        pass

    # 4. Fallback legado de CreateFileW
    try:
        GENERIC_READ = 0x80000000
        GENERIC_WRITE = 0x40000000
        OPEN_EXISTING = 3
        handle = ctypes.windll.kernel32.CreateFileW(
            r"\\.\ViGEmBus",
            GENERIC_READ | GENERIC_WRITE,
            0,
            None,
            OPEN_EXISTING,
            0,
            None
        )
        if handle != -1 and handle != 0:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
    except Exception:
        pass

    return False

def install_vigem_driver_elevation(msi_path: str) -> bool:
    """Dispara a instalação ou reparo do driver com elevação UAC."""
    try:
        # ShellExecuteW com 'runas' abre o prompt nativo do Windows UAC com interface
        ret = ctypes.windll.shell32.ShellExecuteW(
            None,
            "runas",
            "msiexec.exe",
            f'/i "{msi_path}" /norestart',
            None,
            1
        )
        return ret > 32
    except Exception as e:
        print(f"[Driver] Erro ao disparar instalação do ViGEmBus: {e}")
        return False

# ==============================================================================
# 2. GERENCIADOR ADB (USB PLUG & PLAY)
# ==============================================================================

class ADBManager:
    """Monitora conexão USB de celulares e mantém o túnel reverso ativo."""
    def __init__(self, port: int = 5000):
        self.port = port
        self.adb_path = get_adb_path()
        self.device_connected = False
        self.device_name = "Nenhum detectado via USB"
        self.tunnel_active = False
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def start(self):
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False

    def _monitor_loop(self):
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = 0  # SW_HIDE

        while self._running:
            if not self.adb_path:
                self.adb_path = get_adb_path()
                time.sleep(3)
                continue

            try:
                # 1. Verifica dispositivos conectados
                res = subprocess.run(
                    [self.adb_path, "devices"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    startupinfo=startupinfo,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                )
                lines = res.stdout.strip().splitlines()
                attached = []
                for line in lines[1:]:
                    parts = line.strip().split()
                    if len(parts) >= 2 and parts[1] == "device":
                        attached.append(parts[0])

                if attached:
                    dev_id = attached[0]
                    if not self.device_connected or not self.tunnel_active:
                        # Obtém modelo do smartphone
                        try:
                            m_res = subprocess.run(
                                [self.adb_path, "-s", dev_id, "shell", "getprop", "ro.product.model"],
                                capture_output=True,
                                text=True,
                                timeout=2,
                                startupinfo=startupinfo,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                            )
                            model = m_res.stdout.strip()
                            self.device_name = f"{model} ({dev_id})" if model else dev_id
                        except Exception:
                            self.device_name = dev_id

                        # Ativa o túnel USB reverso: celular 127.0.0.1:5000 -> PC 127.0.0.1:5000
                        rev_res = subprocess.run(
                            [self.adb_path, "-s", dev_id, "reverse", f"tcp:{self.port}", f"tcp:{self.port}"],
                            capture_output=True,
                            text=True,
                            timeout=3,
                            startupinfo=startupinfo,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                        )
                        if rev_res.returncode == 0:
                            self.tunnel_active = True
                            self.device_connected = True
                            print(f"[ADB] Túnel reverso USB ativado com sucesso para {self.device_name} (tcp:{self.port})")
                        else:
                            self.tunnel_active = False
                else:
                    if self.device_connected:
                        print("[ADB] Smartphone desconectado da porta USB.")
                    self.device_connected = False
                    self.tunnel_active = False
                    self.device_name = "Nenhum detectado via USB"

            except Exception as e:
                self.device_connected = False
                self.tunnel_active = False

            time.sleep(2.5)

# ==============================================================================
# 3. CONTROLADORES VIRTUAIS (XBOX, PS4, TECLADO)
# ==============================================================================

class BaseController:
    """Interface abstrata de tradução de inputs."""
    def apply_inputs(self, payload: Dict[str, Any], settings: Dict[str, Any]):
        pass

    def release_all(self):
        pass

    def close(self):
        pass


class KeyboardController(BaseController):
    """Controlador que injeta entradas de Teclado DirectInput (WASD / Setas / Ambos).
    Inclui Direção Progressiva Inteligente (PWM Pulse Steering) para curvas suaves
    e graduais sem puxar bruscamente o veículo contra a parede."""
    def __init__(self, key_layout: str = "both"):
        self.key_layout = key_layout # "both", "arrows" ou "wasd"
        self.active_keys = set()
        self._last_assert = {} # key -> timestamp
        self._lock = threading.Lock()

        # Configurações de Direção Progressiva (Pulse Width Modulation)
        self.progressive_steering = True
        self._steer_dir = 0  # -1 = Esquerda, +1 = Direita, 0 = Neutro
        self._steer_magnitude = 0.0  # 0.0 a 1.0
        self._keys_left = ["a"]
        self._keys_right = ["d"]
        self._last_fire = False
        self._last_zoom = False
        self._last_reload = False
        self._running = True
        self._pulse_thread = threading.Thread(target=self._steer_pulse_loop, daemon=True)
        self._pulse_thread.start()

        try:
            import pydirectinput
            self.pdi = pydirectinput
            self.pdi.PAUSE = 0.0
            self.pdi.FAILSAFE = False
        except ImportError:
            self.pdi = None
            print("[Keyboard] Atenção: pydirectinput não encontrado, simulando via SendInput...")

    def _steer_pulse_loop(self):
        """Worker de alta precisão (100Hz / 10ms) que modula as teclas de direção
        conforme o ângulo do volante físico, gerando curvas perfeitamente proporcionais."""
        period_ms = 60.0
        while self._running:
            try:
                with self._lock:
                    s_dir = self._steer_dir
                    s_mag = self._steer_magnitude
                    keys_l = list(self._keys_left)
                    keys_r = list(self._keys_right)
                    prog = self.progressive_steering

                now = time.time()
                if s_dir == 0 or s_mag <= 0.03:
                    # Direção neutra: libera ambas imediatamente
                    self._release_keys(keys_l)
                    self._release_keys(keys_r)
                elif s_dir > 0:
                    # Curva à direita
                    self._release_keys(keys_l)
                    if not prog or s_mag >= 0.75:
                        self._press_keys(keys_r, now)
                    else:
                        cycle_pos = (now * 1000.0) % period_ms
                        active_duration = max(18.0, s_mag * period_ms)
                        if cycle_pos < active_duration:
                            self._press_keys(keys_r, now)
                        else:
                            self._release_keys(keys_r)
                elif s_dir < 0:
                    # Curva à esquerda
                    self._release_keys(keys_r)
                    if not prog or s_mag >= 0.75:
                        self._press_keys(keys_l, now)
                    else:
                        cycle_pos = (now * 1000.0) % period_ms
                        active_duration = max(18.0, s_mag * period_ms)
                        if cycle_pos < active_duration:
                            self._press_keys(keys_l, now)
                        else:
                            self._release_keys(keys_l)
            except Exception:
                pass
            time.sleep(0.010)

    def _press_keys(self, keys: list, now: float):
        for k in keys:
            self._press(k, now)

    def _release_keys(self, keys: list):
        for k in keys:
            self._release(k)

    def _press(self, key: str, now: float):
        is_new = key not in self.active_keys
        self.active_keys.add(key)
        last_t = self._last_assert.get(key, 0.0)
        # Typematic repeat a cada 55ms para garantir que jogos DirectInput mantenham resposta contínua
        if is_new or (now - last_t) >= 0.055:
            self._last_assert[key] = now
            if self.pdi:
                try:
                    self.pdi.keyDown(key)
                except Exception:
                    pass

    def _release(self, key: str):
        if key in self.active_keys:
            self.active_keys.discard(key)
            self._last_assert.pop(key, None)
            if self.pdi:
                try:
                    self.pdi.keyUp(key)
                except Exception:
                    pass

    def _apply_action(self, keys: list, active: bool, now: float):
        for k in keys:
            if active:
                self._press(k, now)
            else:
                self._release(k)

    def apply_inputs(self, payload: Dict[str, Any], settings: Dict[str, Any]):
        now = time.time()
        with self._lock:
            # 0. Reconhecimento do Modo FPS Tático (Counter Strike 1.6 / PC FPS)
            is_fps = payload.get("modo") == "fps" or "mouse_dx" in payload or "disparo" in payload or "recarregar" in payload
            if is_fps:
                # 1. Movimentação Relativa da Mira / Mouse (DirectInput para CS 1.6)
                dx = int(payload.get("mouse_dx", 0))
                dy = int(payload.get("mouse_dy", 0))
                if dx == 0 and dy == 0 and ("joy_rx" in payload or "joy_ry" in payload):
                    rx = float(payload.get("joy_rx", 0.0))
                    ry = float(payload.get("joy_ry", 0.0))
                    rate_sens = {0: 16.0, 1: 28.0, 2: 44.0}.get(settings.get("fps_sens_index", 1), 28.0)
                    dx = int(rx * rate_sens)
                    dy = int(-ry * rate_sens)

                if dx != 0 or dy != 0:
                    win32_mouse_move(dx, dy)

                # 2. Disparo / Tiro com a Arma (Botão Esquerdo / Mouse 1)
                fire = bool(payload.get("disparo", False))
                if fire != self._last_fire:
                    self._last_fire = fire
                    win32_mouse_button("left", fire)

                # 3. Zoom da Arma / Mira Secundária (Botão Direito / Mouse 2)
                zoom = bool(payload.get("zoom", False))
                if zoom != self._last_zoom:
                    self._last_zoom = zoom
                    win32_mouse_button("right", zoom)

                # 4. Recarregar Arma (Tecla 'R' no CS 1.6 ao soltar a mão da base)
                reload_cmd = bool(payload.get("recarregar", False))
                if reload_cmd and not self._last_reload:
                    self._last_reload = True
                    win32_press_reload()
                elif not reload_cmd:
                    self._last_reload = False

                # 5. Locomoção WASD no CS 1.6 (Cabeça / Mesh)
                self._apply_action(["w"], bool(payload.get("cima", False)), now)
                self._apply_action(["s"], bool(payload.get("baixo", False)), now)
                self._apply_action(["a"], bool(payload.get("esquerda", False)), now)
                self._apply_action(["d"], bool(payload.get("direita", False)), now)

                # Libera o volante virtual enquanto joga em modo FPS
                self._steer_dir = 0
                self._steer_magnitude = 0.0
                return

            # 0.1 Reconhecimento do Modo Luta (Stick Fight The Game / Jogos de Luta)
            is_fight = payload.get("modo") in ("luta", "fight") or "ataque" in payload or "defesa" in payload
            if is_fight:
                # Mapeamento oficial solicitado para Stick Fight:
                # C = Ataque (Soco)
                # V = Defesa (Cruzar braços em X)
                # A = Mover corpo para Esquerda
                # D = Mover corpo para Direita
                # W = Pulo
                atk = bool(payload.get("ataque", False))
                defe = bool(payload.get("defesa", False))
                left = bool(payload.get("esquerda", False))
                right = bool(payload.get("direita", False))
                jump = bool(payload.get("pular", False) or payload.get("pulo", False))

                self._apply_action(["c"], atk, now)
                self._apply_action(["v"], defe, now)
                self._apply_action(["a"], left, now)
                self._apply_action(["d"], right, now)
                self._apply_action(["w"], jump, now)

                # Desativa volante virtual
                self._steer_dir = 0
                self._steer_magnitude = 0.0
                return

            angle = float(payload.get("angulo", 0.0))
            if settings.get("invert_steer", False):
                angle = -angle

            deadzone = float(settings.get("deadzone", 3.0))
            max_angle = float(settings.get("max_angle", 35.0))
            layout = settings.get("key_layout", self.key_layout)

            if layout == "arrows":
                self._keys_left = ["left"]
                self._keys_right = ["right"]
                keys_up = ["up"]
                keys_down = ["down"]
            elif layout == "wasd":
                self._keys_left = ["a"]
                self._keys_right = ["d"]
                keys_up = ["w"]
                keys_down = ["s"]
            else: # "both" - Recomendado
                self._keys_left = ["left", "a"]
                self._keys_right = ["right", "d"]
                keys_up = ["up", "w"]
                keys_down = ["down", "s"]
            keys_jump = ["space"]

            # 1. Direção / Volante Proporcional Inteligente (1:1 direto sem corte por zona morta)
            # A centralização é gerida temporalmente (dwell 0.3s) sem degrau rígido de deadzone
            abs_a = abs(angle)
            if abs_a > 0.0:
                mag = abs_a / max(1.0, max_angle)
                self._steer_magnitude = min(1.0, max(0.05, mag))
                self._steer_dir = 1 if angle > 0 else -1
            elif bool(payload.get("direita", False)):
                self._steer_dir = 1
                self._steer_magnitude = 0.5
            elif bool(payload.get("esquerda", False)):
                self._steer_dir = -1
                self._steer_magnitude = 0.5
            else:
                self._steer_dir = 0
                self._steer_magnitude = 0.0

            # 2. Acelerar (Polegar Direito / Cima)
            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))

            # 3. Freio / Ré (Polegar Esquerdo / Baixo)
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))

            # Garante exclusão mútua contra falso ruído simultâneo
            if gas and brake:
                brake = False

            self._apply_action(keys_up, gas, now)
            self._apply_action(keys_down, brake, now)

            # 4. Pulo / Nitro / Espaço
            # Em jogos de corrida, Espaço é freio de mão! NUNCA aplicar freio de mão junto com aceleração
            jump = bool(payload.get("pular", False)) and not gas
            self._apply_action(keys_jump, jump, now)

    def release_all(self):
        with self._lock:
            self._steer_dir = 0
            self._steer_magnitude = 0.0
            if getattr(self, "_last_fire", False):
                win32_mouse_button("left", False)
                self._last_fire = False
            if getattr(self, "_last_zoom", False):
                win32_mouse_button("right", False)
                self._last_zoom = False
            self._last_reload = False
            for k in list(self.active_keys):
                if self.pdi:
                    try:
                        self.pdi.keyUp(k)
                    except Exception:
                        pass
            self.active_keys.clear()
            self._last_assert.clear()

    def close(self):
        self._running = False
        self.release_all()


class Xbox360Controller(BaseController):
    """Emula um controle oficial de Xbox 360 no Windows via ViGEmBus (XInput)."""
    def __init__(self):
        import vgamepad as vg
        self.vg = vg
        self.pad = vg.VX360Gamepad()
        self._lock = threading.Lock()
        print("[XboxController] Controle Virtual Xbox 360 conectado e ativo no Windows!")

    def apply_inputs(self, payload: Dict[str, Any], settings: Dict[str, Any]):
        with self._lock:
            # 0. Reconhecimento do Modo FPS Mesh / Emulação de Joystick com Olhos e Cabeça
            is_fps = payload.get("modo") == "fps" or "joy_rx" in payload or "joy_lx" in payload
            if is_fps:
                # 1. Analógico Direito (Mira / Câmera via Olhos) [-1.0 a +1.0]
                rx = float(payload.get("joy_rx", 0.0))
                ry = float(payload.get("joy_ry", 0.0))
                rx = max(-1.0, min(1.0, rx))
                ry = max(-1.0, min(1.0, ry))
                self.pad.right_joystick_float(x_value_float=rx, y_value_float=ry)

                # 2. Analógico Esquerdo (Movimentação / Locomoção via Cabeça) [-1.0 a +1.0]
                lx = float(payload.get("joy_lx", 0.0))
                ly = float(payload.get("joy_ly", 0.0))
                if lx == 0.0 and ly == 0.0:
                    if payload.get("esquerda", False): lx = -1.0
                    elif payload.get("direita", False): lx = 1.0
                    if payload.get("cima", False): ly = 1.0
                    elif payload.get("baixo", False): ly = -1.0
                lx = max(-1.0, min(1.0, lx))
                ly = max(-1.0, min(1.0, ly))
                self.pad.left_joystick_float(x_value_float=lx, y_value_float=ly)

                # 3. Gatilhos Analógicos (RT = Disparo / Tiro, LT = Mira / Zoom)
                fire = bool(payload.get("disparo", False))
                zoom = bool(payload.get("zoom", False))
                self.pad.right_trigger_float(1.0 if fire else 0.0)
                self.pad.left_trigger_float(1.0 if zoom else 0.0)

                # 4. Botões de Ação (X = Recarregar, A = Pulo)
                reload_cmd = bool(payload.get("recarregar", False))
                if reload_cmd:
                    self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
                else:
                    self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)

                jump = bool(payload.get("pular", False))
                if jump:
                    self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
                else:
                    self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)

                self.pad.update()
                return

            angle = float(payload.get("angulo", 0.0))
            if settings.get("invert_steer", False):
                angle = -angle

            max_angle = float(settings.get("max_angle", 35.0))
            deadzone = float(settings.get("deadzone", 3.0))

            # Cálculo de volante analógico contínuo e suave (-1.0 a +1.0)
            # Resposta direta 1:1 sem zona morta mecânica; centralização gerida por dwell timer
            abs_a = abs(angle)
            if abs_a > 0.0:
                norm_x = min(1.0, abs_a / max(1.0, max_angle))
                if angle < 0:
                    norm_x = -norm_x
            else:
                norm_x = 0.0

            # Botões digitais só atuam em fallback caso não haja ângulo de sensor
            if norm_x == 0.0:
                if payload.get("esquerda", False):
                    norm_x = -1.0
                elif payload.get("direita", False):
                    norm_x = 1.0

            # Eixo analógico do direcional esquerdo (Thumbstick LX)
            self.pad.left_joystick_float(x_value_float=norm_x, y_value_float=0.0)

            # Gatilhos analógicos RT (Acelerador - Polegar Direito) e LT (Freio - Polegar Esquerdo)
            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))
            if gas and brake:
                brake = False
            jump = bool(payload.get("pular", False)) and not gas

            self.pad.right_trigger_float(1.0 if gas else 0.0)
            self.pad.left_trigger_float(1.0 if brake else 0.0)

            # Botão A só é acionado com jump explícito (não em aceleração, pois Botão A é freio de mão em jogos Xbox)
            if jump:
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)

            # Botão X (Freio secundário clássico apenas com freio)
            if brake:
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)

            # D-Pad (Up, Down, Left, Right)
            if payload.get("cima", False):
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)

            if payload.get("baixo", False):
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)

            if payload.get("esquerda", False):
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)

            if payload.get("direita", False):
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)

            # Atualiza o estado físico do controle no driver do Windows
            self.pad.update()

    def release_all(self):
        with self._lock:
            self.pad.reset()
            self.pad.update()

    def close(self):
        self.release_all()
        del self.pad


class PS4Controller(BaseController):
    """Emula um controle oficial de PlayStation 4 (DualShock 4) via ViGEmBus."""
    def __init__(self):
        import vgamepad as vg
        self.vg = vg
        self.pad = vg.VDS4Gamepad()
        self._lock = threading.Lock()
        print("[PS4Controller] Controle Virtual DualShock 4 conectado e ativo no Windows!")

    def apply_inputs(self, payload: Dict[str, Any], settings: Dict[str, Any]):
        with self._lock:
            # 0. Reconhecimento do Modo FPS Mesh / Emulação de Joystick com Olhos e Cabeça
            is_fps = payload.get("modo") == "fps" or "joy_rx" in payload or "joy_lx" in payload
            if is_fps:
                # 1. Analógico Direito (Mira / Câmera via Olhos) - DS4: 128 = Centro
                rx = float(payload.get("joy_rx", 0.0))
                ry = float(payload.get("joy_ry", 0.0))
                thumb_rx = int(128 + max(-1.0, min(1.0, rx)) * 127)
                thumb_ry = int(128 - max(-1.0, min(1.0, ry)) * 127) # Y invertido no DS4
                thumb_rx = max(0, min(255, thumb_rx))
                thumb_ry = max(0, min(255, thumb_ry))
                self.pad.right_joystick(thumb_rx, thumb_ry)

                # 2. Analógico Esquerdo (Movimentação / Locomoção via Cabeça)
                lx = float(payload.get("joy_lx", 0.0))
                ly = float(payload.get("joy_ly", 0.0))
                if lx == 0.0 and ly == 0.0:
                    if payload.get("esquerda", False): lx = -1.0
                    elif payload.get("direita", False): lx = 1.0
                    if payload.get("cima", False): ly = 1.0
                    elif payload.get("baixo", False): ly = -1.0
                thumb_lx = int(128 + max(-1.0, min(1.0, lx)) * 127)
                thumb_ly = int(128 - max(-1.0, min(1.0, ly)) * 127)
                thumb_lx = max(0, min(255, thumb_lx))
                thumb_ly = max(0, min(255, thumb_ly))
                self.pad.left_joystick(thumb_lx, thumb_ly)

                # 3. Gatilhos Analógicos (R2 = Disparo, L2 = Mira / Zoom)
                fire = bool(payload.get("disparo", False))
                zoom = bool(payload.get("zoom", False))
                self.pad.right_trigger_float(1.0 if fire else 0.0)
                self.pad.left_trigger_float(1.0 if zoom else 0.0)

                # 4. Botões de Ação (Quadrado = Recarregar, Cruz = Pulo)
                reload_cmd = bool(payload.get("recarregar", False))
                if reload_cmd:
                    self.pad.press_button(self.vg.DS4_BUTTONS.DS4_BUTTON_SQUARE)
                else:
                    self.pad.release_button(self.vg.DS4_BUTTONS.DS4_BUTTON_SQUARE)

                jump = bool(payload.get("pular", False))
                if jump:
                    self.pad.press_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)
                else:
                    self.pad.release_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)

                self.pad.update()
                return

            angle = float(payload.get("angulo", 0.0))
            if settings.get("invert_steer", False):
                angle = -angle

            max_angle = float(settings.get("max_angle", 35.0))
            deadzone = float(settings.get("deadzone", 3.0))

            abs_a = abs(angle)
            if abs_a > 0.0:
                norm_x = min(1.0, abs_a / max(1.0, max_angle))
                if angle < 0:
                    norm_x = -norm_x
            else:
                norm_x = 0.0

            if norm_x == 0.0:
                if payload.get("esquerda", False):
                    norm_x = -1.0
                elif payload.get("direita", False):
                    norm_x = 1.0

            # No DS4 o analógico vai de 0 a 255 (128 = Centro)
            thumb_lx = int(128 + norm_x * 127)
            thumb_lx = max(0, min(255, thumb_lx))
            self.pad.left_joystick(thumb_lx, 128)

            # Gatilhos R2 (Gás - Polegar Direito) e L2 (Freio - Polegar Esquerdo)
            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))
            if gas and brake:
                brake = False
            jump = bool(payload.get("pular", False)) and not gas

            self.pad.right_trigger_float(1.0 if gas else 0.0)
            self.pad.left_trigger_float(1.0 if brake else 0.0)

            # Botão X (Cruz - apenas com jump explícito)
            if jump:
                self.pad.press_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)
            else:
                self.pad.release_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)

            # Botão Quadrado (Freio)
            if brake:
                self.pad.press_button(self.vg.DS4_BUTTONS.DS4_BUTTON_SQUARE)
            else:
                self.pad.release_button(self.vg.DS4_BUTTONS.DS4_BUTTON_SQUARE)

            self.pad.update()

    def release_all(self):
        with self._lock:
            self.pad.reset()
            self.pad.update()

    def close(self):
        self.release_all()
        del self.pad

# ==============================================================================
# 4. RECEPTOR DE REDE (TCP TÚNEL USB + UDP WI-FI)
# ==============================================================================

class NetworkReceiver:
    """Escuta simultaneamente conexões TCP (ADB Reverse), UDP (Wi-Fi/LAN) e Bluetooth (RFCOMM/Serial)."""
    def __init__(self, port: int = 5000, on_packet_callback=None):
        self.port = port
        self.on_packet_callback = on_packet_callback
        self.running = False
        self.last_packet_time = 0.0
        self.is_receiving = False
        self.packets_count = 0
        self.active_protocol = "Nenhum"
        self.bt_channel = 4
        self.bluetooth_available = False
        self._thread: Optional[threading.Thread] = None
        self._serial_thread: Optional[threading.Thread] = None

    def start(self):
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._server_loop, daemon=True)
        self._thread.start()
        self._serial_thread = threading.Thread(target=self._bluetooth_serial_loop, daemon=True)
        self._serial_thread.start()

    def stop(self):
        self.running = False

    def _bluetooth_serial_loop(self):
        """Escuta conexões em portas seriais virtuais Bluetooth (SPP / COM Port)."""
        attach_thread_to_input_desktop()
        try:
            import serial
            import serial.tools.list_ports
        except ImportError:
            return

        while self.running:
            try:
                # Localiza portas COM Bluetooth configuradas no Windows
                ports = [p.device for p in serial.tools.list_ports.comports() 
                         if 'BTH' in (p.hwid or '') or 'Bluetooth' in (p.description or '')]
                for port in ports:
                    if not self.running:
                        break
                    try:
                        with serial.Serial(port, baudrate=115200, timeout=0.5) as ser:
                            while self.running:
                                line = ser.readline()
                                if line:
                                    text = line.decode('utf-8', errors='ignore').strip()
                                    if text:
                                        self._handle_raw_message(text, proto=f"Bluetooth ({port})")
                    except Exception:
                        pass
            except Exception:
                pass
            time.sleep(2.0)

    def _server_loop(self):
        attach_thread_to_input_desktop()
        # 1. Configura Socket UDP
        udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            udp_sock.bind(("0.0.0.0", self.port))
            udp_sock.setblocking(False)
            print(f"[Rede] Servidor UDP ativo escutando em 0.0.0.0:{self.port}")
        except Exception as e:
            print(f"[Rede] Falha ao bindar UDP na porta {self.port}: {e}")
            udp_sock = None

        # 2. Configura Socket TCP
        tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            tcp_sock.bind(("0.0.0.0", self.port))
            tcp_sock.listen(5)
            tcp_sock.setblocking(False)
            print(f"[Rede] Servidor TCP ativo escutando em 0.0.0.0:{self.port} (Túnel USB ADB)")
        except Exception as e:
            print(f"[Rede] Falha ao bindar TCP na porta {self.port}: {e}")
            tcp_sock = None

        # 3. Configura Socket Bluetooth RFCOMM (Sem Fio Direto)
        bt_sock = None
        bt_clients = []
        bt_buffers = {}
        if hasattr(socket, 'AF_BLUETOOTH') and hasattr(socket, 'BTPROTO_RFCOMM'):
            for ch in [4, 5, 6, 7]:
                try:
                    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
                    s.bind((getattr(socket, 'BDADDR_ANY', '00:00:00:00:00:00'), ch))
                    s.listen(2)
                    s.setblocking(False)
                    bt_sock = s
                    self.bt_channel = ch
                    self.bluetooth_available = True
                    print(f"[Rede] Servidor Bluetooth RFCOMM ativo (Canal {ch}) - Pronto para conexões sem fios!")
                    break
                except Exception:
                    pass
            if not bt_sock:
                print("[Rede] Bluetooth RFCOMM indisponível ou adaptador desativado no Windows.")

        tcp_clients = []
        tcp_buffers = {}

        while self.running:
            read_sockets = []
            if udp_sock:
                read_sockets.append(udp_sock)
            if tcp_sock:
                read_sockets.append(tcp_sock)
            if bt_sock:
                read_sockets.append(bt_sock)
            read_sockets.extend(tcp_clients)
            read_sockets.extend(bt_clients)

            try:
                readable, _, exceptional = select.select(read_sockets, [], read_sockets, 0.001)
            except Exception:
                continue

            now = time.time()

            for s in readable:
                if s is tcp_sock:
                    # Nova conexão TCP de entrada
                    try:
                        client_sock, client_addr = tcp_sock.accept()
                        client_sock.setblocking(False)
                        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        tcp_clients.append(client_sock)
                        tcp_buffers[client_sock] = ""
                        try:
                            client_sock.sendall(b'{"status":"connected"}\n')
                        except Exception:
                            pass
                        print(f"[Rede] Cliente TCP conectado de {client_addr} (USB ADB Reverse)")
                    except Exception:
                        pass

                elif s is bt_sock:
                    # Nova conexão Bluetooth RFCOMM de entrada
                    try:
                        client_sock, client_addr = bt_sock.accept()
                        client_sock.setblocking(False)
                        bt_clients.append(client_sock)
                        bt_buffers[client_sock] = ""
                        try:
                            client_sock.sendall(b'{"status":"connected","type":"bluetooth"}\n')
                        except Exception:
                            pass
                        print(f"[Rede] Cliente Bluetooth conectado de {client_addr} (RFCOMM Sem Fio)")
                    except Exception:
                        pass

                elif s is udp_sock:
                    # Pacote UDP recebido
                    try:
                        data, addr = udp_sock.recvfrom(4096)
                        if data:
                            # Prioridade total para conexão cabeada ou bluetooth direto
                            if tcp_clients or bt_clients:
                                continue
                            try:
                                udp_sock.sendto(b'{"status":"connected"}\n', addr)
                            except Exception:
                                pass
                            self._handle_raw_message(data.decode('utf-8', errors='ignore'), proto="UDP (Wi-Fi/LAN)")
                    except Exception:
                        pass

                elif s in bt_clients:
                    # Dados recebidos de um cliente Bluetooth RFCOMM
                    try:
                        chunk = s.recv(4096)
                        if chunk:
                            text = chunk.decode('utf-8', errors='ignore')
                            bt_buffers[s] = bt_buffers.get(s, "") + text
                            while "\n" in bt_buffers[s]:
                                line, bt_buffers[s] = bt_buffers[s].split("\n", 1)
                                line = line.strip()
                                if line:
                                    self._handle_raw_message(line, proto="Bluetooth (RFCOMM)")
                        else:
                            if s in bt_clients:
                                bt_clients.remove(s)
                            bt_buffers.pop(s, None)
                            s.close()
                    except Exception:
                        if s in bt_clients:
                            bt_clients.remove(s)
                        bt_buffers.pop(s, None)
                        try:
                            s.close()
                        except Exception:
                            pass

                else:
                    # Dados recebidos de um cliente TCP existente
                    try:
                        chunk = s.recv(4096)
                        if chunk:
                            text = chunk.decode('utf-8', errors='ignore')
                            tcp_buffers[s] = tcp_buffers.get(s, "") + text
                            # Processa linhas completas com delimitador \n
                            while "\n" in tcp_buffers[s]:
                                line, tcp_buffers[s] = tcp_buffers[s].split("\n", 1)
                                line = line.strip()
                                if line:
                                    self._handle_raw_message(line, proto="TCP (USB ADB)")
                        else:
                            # Cliente fechou conexão
                            if s in tcp_clients:
                                tcp_clients.remove(s)
                            tcp_buffers.pop(s, None)
                            s.close()
                    except Exception:
                        if s in tcp_clients:
                            tcp_clients.remove(s)
                        tcp_buffers.pop(s, None)
                        try:
                            s.close()
                        except Exception:
                            pass

            for s in exceptional:
                if s in tcp_clients:
                    tcp_clients.remove(s)
                tcp_buffers.pop(s, None)
                if s in bt_clients:
                    bt_clients.remove(s)
                bt_buffers.pop(s, None)
                try:
                    s.close()
                except Exception:
                    pass

            # Fail-safe: Detecta se parou de receber pacotes por mais de 2.5 segundos
            if self.is_receiving and (now - self.last_packet_time) > 2.5:
                self.is_receiving = False
                self.active_protocol = "Inativo (Aguardando)"
                if self.on_packet_callback:
                    self.on_packet_callback(None, is_timeout=True)

        # Encerramento limpo
        if udp_sock:
            udp_sock.close()
        if tcp_sock:
            tcp_sock.close()
        if bt_sock:
            try:
                bt_sock.close()
            except Exception:
                pass
        for c in tcp_clients:
            try:
                c.close()
            except Exception:
                pass
        for c in bt_clients:
            try:
                c.close()
            except Exception:
                pass

    def _handle_raw_message(self, raw_str: str, proto: str):
        try:
            payload = json.loads(raw_str)
            if isinstance(payload, dict):
                self.last_packet_time = time.time()
                self.is_receiving = True
                self.packets_count += 1
                self.active_protocol = proto
                if self.on_packet_callback:
                    self.on_packet_callback(payload, is_timeout=False)
        except Exception:
            pass

# ==============================================================================
# 5. GERENCIADOR DO HUB DE CONTROLE
# ==============================================================================

class ControllerBridgeHub:
    """Núcleo central coordenando rede, detecção ADB e injeção nos emuladores."""
    def __init__(self):
        self.adb = ADBManager(port=5000)
        self.network = NetworkReceiver(port=5000, on_packet_callback=self._on_packet)
        self.active_mode = "keyboard" # "xbox", "ps4", "keyboard"
        self.controller: Optional[BaseController] = None
        self.current_payload: Dict[str, Any] = {}
        self.settings = {
            "max_angle": 45.0,
            "deadzone": 5.0,
            "invert_steer": False,
            "key_layout": "both" # "both", "arrows" ou "wasd"
        }
        self.vigem_installed = check_vigem_driver()
        self.is_connected = False
        self.on_connection_change = None

    def start(self):
        self.adb.start()
        self.network.start()
        self.set_mode(self.active_mode)

    def stop(self):
        self.adb.stop()
        self.network.stop()
        if self.controller:
            self.controller.release_all()
            self.controller.close()
            self.controller = None

    def refresh_vigem_status(self) -> bool:
        self.vigem_installed = check_vigem_driver()
        return self.vigem_installed

    def set_mode(self, mode: str) -> bool:
        """Alterna o modo de emulação (xbox, ps4, keyboard)."""
        if self.controller:
            self.controller.release_all()
            self.controller.close()
            self.controller = None

        self.vigem_installed = check_vigem_driver()

        if mode == "xbox":
            if not self.vigem_installed:
                print("[Hub] ViGEmBus não encontrado! Revertendo para Teclado.")
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.settings["key_layout"])
                return False
            try:
                self.controller = Xbox360Controller()
                self.active_mode = "xbox"
                return True
            except Exception as e:
                print(f"[Hub] Erro ao criar XboxController: {e}")
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.settings["key_layout"])
                return False

        elif mode == "ps4":
            if not self.vigem_installed:
                print("[Hub] ViGEmBus não encontrado! Revertendo para Teclado.")
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.settings["key_layout"])
                return False
            try:
                self.controller = PS4Controller()
                self.active_mode = "ps4"
                return True
            except Exception as e:
                print(f"[Hub] Erro ao criar PS4Controller: {e}")
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.settings["key_layout"])
                return False

        else:
            self.active_mode = "keyboard"
            self.controller = KeyboardController(key_layout=self.settings["key_layout"])
            return True

    def _on_packet(self, payload: Optional[Dict[str, Any]], is_timeout: bool):
        was_connected = self.is_connected
        if is_timeout or payload is None:
            self.current_payload = {}
            self.is_connected = False
            if self.controller:
                self.controller.release_all()
            if was_connected and self.on_connection_change:
                self.on_connection_change(False, "Inativo", self.adb.device_name)
            if hasattr(self, "_fps_direct_helper"):
                self._fps_direct_helper.release_all()
        else:
            self.current_payload = payload
            self.is_connected = True

            # Sincronização dinâmica com calibração enviada pelo smartphone
            if "max_angulo" in payload:
                try:
                    self.settings["max_angle"] = float(payload["max_angulo"])
                except Exception:
                    pass
            if "zona_morta" in payload:
                try:
                    self.settings["deadzone"] = float(payload["zona_morta"])
                except Exception:
                    pass

            if not was_connected and self.on_connection_change:
                self.on_connection_change(True, self.network.active_protocol, self.adb.device_name)
            if self.controller:
                self.controller.apply_inputs(payload, self.settings)

            # Se estiver em modo FPS ou Luta e o controle atual não for Teclado, o helper direto garante DirectInput
            if payload.get("modo") in ("fps", "luta", "fight"):
                if self.active_mode != "keyboard":
                    if not hasattr(self, "_fps_direct_helper"):
                        self._fps_direct_helper = KeyboardController()
                    self._fps_direct_helper.apply_inputs(payload, self.settings)
            elif hasattr(self, "_fps_direct_helper"):
                self._fps_direct_helper.release_all()

# ==============================================================================
# 6. INTERFACE GRÁFICA MODERNA (TKINTER DARK MODE)
# ==============================================================================

class ModernBridgeGUI:
    """Interface Gráfica completa e intuitiva com telemetria ao vivo."""
    def __init__(self, hub: ControllerBridgeHub, standalone: bool = True):
        self.hub = hub
        self.standalone = standalone
        import tkinter as tk
        from tkinter import ttk, messagebox
        self.tk = tk
        self.ttk = ttk
        self.messagebox = messagebox

        self.root = tk.Tk()
        self.root.title("🎮 Mobile Controller Bridge - Volante & Gamepad Universal")
        self.root.geometry("640x740")
        self.root.minsize(580, 680)
        self.root.configure(bg="#12131C")

        # Configura estilo Dark Theme
        self._setup_styles()
        self._build_widgets()

        # Inicia Hub de controle
        self.hub.start()

        # Loop de atualização visual (30 FPS)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._update_ui_loop()

    def _setup_styles(self):
        style = self.ttk.Style()
        style.theme_use('clam')
        style.configure("TLabel", background="#12131C", foreground="#E0E6ED", font=("Segoe UI", 10))
        style.configure("Card.TFrame", background="#1A1C29", relief="flat")
        style.configure("Header.TLabel", background="#12131C", foreground="#00E5FF", font=("Segoe UI", 16, "bold"))
        style.configure("SubHeader.TLabel", background="#12131C", foreground="#94A3B8", font=("Segoe UI", 9))
        style.configure("Status.TLabel", background="#1A1C29", foreground="#38EF7D", font=("Segoe UI", 11, "bold"))
        style.configure("Mode.TRadiobutton", background="#1A1C29", foreground="#E2E8F0", font=("Segoe UI", 10, "bold"))

    def _build_widgets(self):
        main_container = self.tk.Frame(self.root, bg="#12131C", padx=16, pady=12)
        main_container.pack(fill="both", expand=True)

        # 1. CABEÇALHO
        header_frame = self.tk.Frame(main_container, bg="#12131C")
        header_frame.pack(fill="x", pady=(0, 10))

        title_lbl = self.tk.Label(
            header_frame,
            text="🎮 MOBILE CONTROLLER BRIDGE",
            bg="#12131C",
            fg="#00E5FF",
            font=("Segoe UI", 15, "bold")
        )
        title_lbl.pack(anchor="w")

        sub_lbl = self.tk.Label(
            header_frame,
            text="Transforme seu smartphone em um controle real de PC (Xbox 360, PS4 ou Teclado)",
            bg="#12131C",
            fg="#94A3B8",
            font=("Segoe UI", 9)
        )
        sub_lbl.pack(anchor="w")

        # 2. STATUS CARD (CONEXÃO & ADB)
        status_card = self.tk.Frame(main_container, bg="#1A1C29", padx=14, pady=12, highlightthickness=1, highlightbackground="#2A2E43")
        status_card.pack(fill="x", pady=6)

        row1 = self.tk.Frame(status_card, bg="#1A1C29")
        row1.pack(fill="x", pady=2)
        self.lbl_conn_indicator = self.tk.Label(row1, text="🔴 DESCONECTADO", bg="#1A1C29", fg="#FF5252", font=("Segoe UI", 11, "bold"))
        self.lbl_conn_indicator.pack(side="left")

        self.lbl_proto = self.tk.Label(row1, text="Protocolo: Inativo", bg="#1A1C29", fg="#94A3B8", font=("Segoe UI", 9))
        self.lbl_proto.pack(side="right")

        row2 = self.tk.Frame(status_card, bg="#1A1C29")
        row2.pack(fill="x", pady=(4, 0))
        self.lbl_device = self.tk.Label(row2, text="📱 Dispositivo USB: Verificando...", bg="#1A1C29", fg="#CBD5E1", font=("Segoe UI", 9))
        self.lbl_device.pack(side="left")

        self.lbl_packets = self.tk.Label(row2, text="Pacotes: 0", bg="#1A1C29", fg="#CBD5E1", font=("Segoe UI", 9))
        self.lbl_packets.pack(side="right")

        # 3. SELEÇÃO DE MODO DE CONTROLE
        mode_card = self.tk.Frame(main_container, bg="#1A1C29", padx=14, pady=12, highlightthickness=1, highlightbackground="#2A2E43")
        mode_card.pack(fill="x", pady=6)

        mode_title = self.tk.Label(mode_card, text="MODO DE INTERPRETAÇÃO NO WINDOWS", bg="#1A1C29", fg="#00E5FF", font=("Segoe UI", 10, "bold"))
        mode_title.pack(anchor="w", pady=(0, 8))

        self.mode_var = self.tk.StringVar(value=self.hub.active_mode)

        mode_opts = self.tk.Frame(mode_card, bg="#1A1C29")
        mode_opts.pack(fill="x")

        r_xbox = self.tk.Radiobutton(
            mode_opts, text="🎮 Controle Xbox 360 (XInput)",
            variable=self.mode_var, value="xbox",
            command=self._on_mode_change,
            bg="#1A1C29", fg="#E2E8F0", selectcolor="#252A40",
            activebackground="#1A1C29", activeforeground="#00E5FF",
            font=("Segoe UI", 9, "bold")
        )
        r_xbox.pack(anchor="w", pady=2)

        r_ps4 = self.tk.Radiobutton(
            mode_opts, text="🎮 Controle PlayStation 4 (DS4)",
            variable=self.mode_var, value="ps4",
            command=self._on_mode_change,
            bg="#1A1C29", fg="#E2E8F0", selectcolor="#252A40",
            activebackground="#1A1C29", activeforeground="#00E5FF",
            font=("Segoe UI", 9, "bold")
        )
        r_ps4.pack(anchor="w", pady=2)

        r_kbd = self.tk.Radiobutton(
            mode_opts, text="⌨️ Teclado Gamer DirectInput (WASD / Setas / Espaço)",
            variable=self.mode_var, value="keyboard",
            command=self._on_mode_change,
            bg="#1A1C29", fg="#E2E8F0", selectcolor="#252A40",
            activebackground="#1A1C29", activeforeground="#00E5FF",
            font=("Segoe UI", 9, "bold")
        )
        r_kbd.pack(anchor="w", pady=2)

        # Opção de layout de teclado
        self.kbd_layout_frame = self.tk.Frame(mode_card, bg="#1A1C29")
        self.kbd_layout_frame.pack(fill="x", pady=(6, 0))
        self.tk.Label(self.kbd_layout_frame, text="Teclas:", bg="#1A1C29", fg="#94A3B8", font=("Segoe UI", 8)).pack(side="left")
        self.layout_var = self.tk.StringVar(value="both")
        r_both = self.tk.Radiobutton(self.kbd_layout_frame, text="Ambos (Setas + WASD) [Recomendado]", variable=self.layout_var, value="both", command=self._on_layout_change, bg="#1A1C29", fg="#38EF7D", selectcolor="#252A40", font=("Segoe UI", 8, "bold"))
        r_both.pack(side="left", padx=(6, 4))
        r_arr = self.tk.Radiobutton(self.kbd_layout_frame, text="Setas", variable=self.layout_var, value="arrows", command=self._on_layout_change, bg="#1A1C29", fg="#E2E8F0", selectcolor="#252A40", font=("Segoe UI", 8))
        r_arr.pack(side="left", padx=4)
        r_wasd = self.tk.Radiobutton(self.kbd_layout_frame, text="WASD", variable=self.layout_var, value="wasd", command=self._on_layout_change, bg="#1A1C29", fg="#E2E8F0", selectcolor="#252A40", font=("Segoe UI", 8))
        r_wasd.pack(side="left", padx=4)

        # 4. TELEMETRIA E VOLANTE VISUAL
        telem_card = self.tk.Frame(main_container, bg="#1A1C29", padx=14, pady=12, highlightthickness=1, highlightbackground="#2A2E43")
        telem_card.pack(fill="x", pady=6)

        telem_header = self.tk.Frame(telem_card, bg="#1A1C29")
        telem_header.pack(fill="x", pady=(0, 4))
        self.tk.Label(telem_header, text="TELEMETRIA DO VOLANTE EM TEMPO REAL", bg="#1A1C29", fg="#00E5FF", font=("Segoe UI", 10, "bold")).pack(side="left")
        self.lbl_angle_value = self.tk.Label(telem_header, text="0.0°", bg="#1A1C29", fg="#38EF7D", font=("Segoe UI", 11, "bold"))
        self.lbl_angle_value.pack(side="right")

        # Canvas da barra do volante
        self.canvas_wheel = self.tk.Canvas(telem_card, height=44, bg="#10111A", highlightthickness=1, highlightbackground="#2A2E43")
        self.canvas_wheel.pack(fill="x", pady=6)

        # Indicadores Digitais de Ações
        btns_row = self.tk.Frame(telem_card, bg="#1A1C29")
        btns_row.pack(fill="x", pady=(6, 0))

        self.badge_gas = self.tk.Label(btns_row, text="GAS / CIMA", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=8, pady=4)
        self.badge_gas.pack(side="left", expand=True, fill="x", padx=2)

        self.badge_brake = self.tk.Label(btns_row, text="FREIO / BAIXO", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=8, pady=4)
        self.badge_brake.pack(side="left", expand=True, fill="x", padx=2)

        self.badge_jump = self.tk.Label(btns_row, text="PULO / NITRO", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=8, pady=4)
        self.badge_jump.pack(side="left", expand=True, fill="x", padx=2)

        self.badge_hands = self.tk.Label(btns_row, text="GESTOS: OFF", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=8, pady=4)
        self.badge_hands.pack(side="left", expand=True, fill="x", padx=2)

        # 5. AJUSTES DE SENSIBILIDADE
        settings_card = self.tk.Frame(main_container, bg="#1A1C29", padx=14, pady=10, highlightthickness=1, highlightbackground="#2A2E43")
        settings_card.pack(fill="x", pady=6)

        s_header = self.tk.Label(settings_card, text="CALIBRAÇÃO E SENSIBILIDADE", bg="#1A1C29", fg="#00E5FF", font=("Segoe UI", 10, "bold"))
        s_header.pack(anchor="w", pady=(0, 6))

        s_row1 = self.tk.Frame(settings_card, bg="#1A1C29")
        s_row1.pack(fill="x", pady=2)

        self.tk.Label(s_row1, text="Ângulo Máximo:", bg="#1A1C29", fg="#CBD5E1", font=("Segoe UI", 9)).pack(side="left")
        self.combo_max_angle = self.ttk.Combobox(s_row1, values=["30°", "45°", "60°", "90°"], width=6, state="readonly")
        self.combo_max_angle.set("45°")
        self.combo_max_angle.pack(side="left", padx=8)
        self.combo_max_angle.bind("<<ComboboxSelected>>", self._on_settings_change)

        self.tk.Label(s_row1, text="Zona Morta:", bg="#1A1C29", fg="#CBD5E1", font=("Segoe UI", 9)).pack(side="left", padx=(12, 0))
        self.combo_deadzone = self.ttk.Combobox(s_row1, values=["0°", "3°", "5°", "8°", "12°"], width=5, state="readonly")
        self.combo_deadzone.set("5°")
        self.combo_deadzone.pack(side="left", padx=8)
        self.combo_deadzone.bind("<<ComboboxSelected>>", self._on_settings_change)

        self.invert_var = self.tk.BooleanVar(value=False)
        chk_inv = self.tk.Checkbutton(
            s_row1, text="Inverter Direção",
            variable=self.invert_var, command=self._on_settings_change,
            bg="#1A1C29", fg="#CBD5E1", selectcolor="#252A40",
            activebackground="#1A1C29", activeforeground="#00E5FF",
            font=("Segoe UI", 9)
        )
        chk_inv.pack(side="right")

        # 6. DRIVER VIGEMBUS E FERRAMENTAS DO WINDOWS
        driver_card = self.tk.Frame(main_container, bg="#1A1C29", padx=14, pady=10, highlightthickness=1, highlightbackground="#2A2E43")
        driver_card.pack(fill="x", pady=6)

        d_row = self.tk.Frame(driver_card, bg="#1A1C29")
        d_row.pack(fill="x")

        self.lbl_driver_status = self.tk.Label(d_row, text="Driver ViGEmBus: Verificando...", bg="#1A1C29", fg="#94A3B8", font=("Segoe UI", 9, "bold"))
        self.lbl_driver_status.pack(side="left")

        self.btn_install_driver = self.tk.Button(
            d_row, text="📦 Instalar Driver Xbox/PS4",
            command=self._install_driver,
            bg="#2563EB", fg="#FFFFFF", activebackground="#1D4ED8", activeforeground="#FFFFFF",
            relief="flat", font=("Segoe UI", 9, "bold"), padx=10, pady=2, cursor="hand2"
        )
        self.btn_install_driver.pack(side="right", padx=4)

        self.btn_joy_cpl = self.tk.Button(
            d_row, text="🎮 Testador do Windows",
            command=self._open_joy_cpl,
            bg="#334155", fg="#FFFFFF", activebackground="#475569", activeforeground="#FFFFFF",
            relief="flat", font=("Segoe UI", 9), padx=10, pady=2, cursor="hand2"
        )
        self.btn_joy_cpl.pack(side="right", padx=4)

    def _on_mode_change(self):
        desired_mode = self.mode_var.get()
        success = self.hub.set_mode(desired_mode)
        if not success:
            self.mode_var.set("keyboard")
            self.messagebox.showwarning(
                "Driver ViGEmBus Necessário",
                "Para utilizar o modo de Controle Oficial Xbox 360 ou PS4, é necessário instalar o driver ViGEmBus.\n\n"
                "Clique no botão '📦 Instalar Driver Xbox/PS4' no painel inferior para instalar com 1 clique!\n\n"
                "Enquanto isso, o modo Teclado DirectInput está ativo e funciona normalmente."
            )

    def _on_layout_change(self):
        self.hub.settings["key_layout"] = self.layout_var.get()
        if self.hub.active_mode == "keyboard":
            self.hub.set_mode("keyboard")

    def _on_settings_change(self, event=None):
        try:
            m_a = float(self.combo_max_angle.get().replace("°", ""))
            self.hub.settings["max_angle"] = m_a
        except Exception:
            pass
        try:
            d_z = float(self.combo_deadzone.get().replace("°", ""))
            self.hub.settings["deadzone"] = d_z
        except Exception:
            pass
        self.hub.settings["invert_steer"] = self.invert_var.get()

    def _install_driver(self):
        msi = get_vigem_msi_path()
        if not msi:
            self.messagebox.showerror("Erro", "Arquivo ViGEmBusSetup_x64.msi não encontrado na pasta de instalação.")
            return

        ok = install_vigem_driver_elevation(msi)
        if ok:
            self.messagebox.showinfo(
                "Instalador Iniciado",
                "O instalador oficial do ViGEmBus foi disparado com permissão de Administrador.\n\n"
                "Se a janela de confirmação do Windows apareceu, clique em 'Sim' para concluir."
            )
        else:
            self.messagebox.showerror("Erro", "Não foi possível disparar o instalador com privilégios de Administrador.")

    def _open_joy_cpl(self):
        try:
            subprocess.Popen(["joy.cpl"], shell=True)
        except Exception as e:
            self.messagebox.showerror("Erro", f"Não foi possível abrir joy.cpl: {e}")

    def _update_ui_loop(self):
        # 1. Atualiza Status de Conexão
        is_rec = self.hub.network.is_receiving
        if is_rec:
            self.lbl_conn_indicator.config(text="🟢 CONECTADO", fg="#38EF7D")
        else:
            self.lbl_conn_indicator.config(text="🔴 AGUARDANDO APP", fg="#FF5252")

        self.lbl_proto.config(text=f"Origem: {self.hub.network.active_protocol}")
        self.lbl_device.config(text=f"📱 USB: {self.hub.adb.device_name}")
        self.lbl_packets.config(text=f"Pacotes: {self.hub.network.packets_count}")

        # 2. Driver ViGEmBus
        vigem_ok = self.hub.refresh_vigem_status()
        if vigem_ok:
            self.lbl_driver_status.config(text="✅ Driver ViGEmBus Instalado", fg="#38EF7D")
            self.btn_install_driver.config(state="disabled", text="Driver OK")
        else:
            self.lbl_driver_status.config(text="⚠️ ViGEmBus Não Instalado", fg="#F59E0B")
            self.btn_install_driver.config(state="normal", text="📦 Instalar Driver Xbox/PS4")

        # 3. Telemetria do Volante e Botões
        payload = self.hub.current_payload
        angle = float(payload.get("angulo", 0.0))
        if self.hub.settings["invert_steer"]:
            angle = -angle

        self.lbl_angle_value.config(text=f"{angle:+.1f}°")

        # Desenho no Canvas
        c = self.canvas_wheel
        w = c.winfo_width()
        h = c.winfo_height()
        if w > 20 and h > 10:
            c.delete("all")
            mid_x = w / 2
            mid_y = h / 2

            # Fundo e escala
            c.create_rectangle(10, mid_y - 2, w - 10, mid_y + 2, fill="#252A40", outline="")
            c.create_line(mid_x, 6, mid_x, h - 6, fill="#64748B", width=2) # Centro

            # Zona morta
            dz_ratio = self.hub.settings["deadzone"] / max(1.0, self.hub.settings["max_angle"])
            dz_px = dz_ratio * (mid_x - 20)
            c.create_rectangle(mid_x - dz_px, mid_y - 6, mid_x + dz_px, mid_y + 6, fill="#1E2338", outline="#2F3650")

            # Indicador de posição do volante
            max_a = max(1.0, self.hub.settings["max_angle"])
            ratio = max(-1.0, min(1.0, angle / max_a))
            target_x = mid_x + ratio * (mid_x - 24)

            # Barra proporcional preenchida
            color_bar = "#00E5FF" if abs(angle) > self.hub.settings["deadzone"] else "#475569"
            if ratio < 0:
                c.create_rectangle(target_x, mid_y - 6, mid_x, mid_y + 6, fill=color_bar, outline="")
            else:
                c.create_rectangle(mid_x, mid_y - 6, target_x, mid_y + 6, fill=color_bar, outline="")

            # Marcador do volante
            c.create_oval(target_x - 9, mid_y - 9, target_x + 9, mid_y + 9, fill="#38EF7D", outline="#FFFFFF", width=2)

        # Badges de Ação
        gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
        brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))
        jump = bool(payload.get("pular", False))
        detect = bool(payload.get("detect", False))
        p_dir = bool(payload.get("polegar_dir", False))
        p_esq = bool(payload.get("polegar_esq", False))

        self.badge_gas.config(
            text=f"ACEL [D]: {'ON (W/RT)' if gas else 'OFF'}",
            bg="#16A34A" if gas else "#252A40",
            fg="#FFFFFF" if gas else "#64748B"
        )
        self.badge_brake.config(
            text=f"FREIO [E]: {'ON (S/LT)' if brake else 'OFF'}",
            bg="#DC2626" if brake else "#252A40",
            fg="#FFFFFF" if brake else "#64748B"
        )
        self.badge_jump.config(
            bg="#2563EB" if jump else "#252A40",
            fg="#FFFFFF" if jump else "#64748B"
        )
        thumbs_str = []
        if p_dir:
            thumbs_str.append("👍DIR (ACEL)")
        if p_esq:
            thumbs_str.append("👍ESQ (FREIO)")
        thumbs_txt = " | ".join(thumbs_str) if thumbs_str else "NEUTRO"
        self.badge_hands.config(
            text=f"POLEGARES: {thumbs_txt}",
            bg="#059669" if (p_dir or p_esq) else "#252A40",
            fg="#FFFFFF" if (p_dir or p_esq) else "#64748B"
        )

        # Próximo frame (30 FPS -> ~33ms)
        self.root.after(33, self._update_ui_loop)

    def _on_close(self):
        if hasattr(self, 'standalone') and self.standalone:
            self.hub.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()

# ==============================================================================
# 7. GERENCIADOR DE INICIALIZAÇÃO E INSTALAÇÃO (WINDOWS STARTUP)
# ==============================================================================

class WindowsAutostart:
    """Gerencia instalação portátil e auto-inicialização com o Windows via Registro (HKCU\\...\\Run)."""
    REG_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
    APP_NAME = "FUAGMobileControllerBridge"

    @classmethod
    def get_installed_dir(cls) -> str:
        return os.path.expandvars(r"%LOCALAPPDATA%\FUAG")

    @classmethod
    def get_installed_exe_path(cls) -> str:
        return os.path.join(cls.get_installed_dir(), "MobileControllerBridge.exe")

    @classmethod
    def is_running_installed(cls) -> bool:
        current_exe = sys.executable if getattr(sys, 'frozen', False) else os.path.abspath(sys.argv[0])
        installed_exe = cls.get_installed_exe_path()
        return os.path.normcase(os.path.abspath(current_exe)) == os.path.normcase(os.path.abspath(installed_exe))

    @classmethod
    def is_autostart_enabled(cls) -> bool:
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, cls.REG_KEY, 0, winreg.KEY_READ) as key:
                val, _ = winreg.QueryValueEx(key, cls.APP_NAME)
                return bool(val)
        except Exception:
            return False

    @classmethod
    def set_autostart(cls, enable: bool = True, custom_path: Optional[str] = None) -> bool:
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, cls.REG_KEY, 0, winreg.KEY_SET_VALUE) as key:
                if enable:
                    exe = custom_path or (sys.executable if getattr(sys, 'frozen', False) else os.path.abspath(sys.argv[0]))
                    cmd = f'"{exe}" --background'
                    winreg.SetValueEx(key, cls.APP_NAME, 0, winreg.REG_SZ, cmd)
                    print(f"[Autostart] Configurado com sucesso para iniciar com o Windows: {cmd}")
                else:
                    try:
                        winreg.DeleteValue(key, cls.APP_NAME)
                        print("[Autostart] Removido com sucesso da inicialização do Windows.")
                    except FileNotFoundError:
                        pass
                return True
        except Exception as e:
            print(f"[Autostart] Erro ao configurar registro: {e}")
            return False

    @classmethod
    def install_self(cls) -> bool:
        """Instala o executável em %LOCALAPPDATA%\\FUAG, configura inicialização e atalhos."""
        try:
            target_dir = cls.get_installed_dir()
            os.makedirs(target_dir, exist_ok=True)
            target_exe = cls.get_installed_exe_path()
            
            if getattr(sys, 'frozen', False):
                current_exe = sys.executable
            else:
                current_exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "MobileControllerBridge.exe")
                if not os.path.exists(current_exe):
                    current_exe = sys.executable
            
            # Copia executável se não estiver já no destino
            if os.path.exists(current_exe) and os.path.normcase(os.path.abspath(current_exe)) != os.path.normcase(os.path.abspath(target_exe)):
                shutil.copy2(current_exe, target_exe)
                print(f"[Instalador] Executável copiado para: {target_exe}")

            # Copia pasta tools se existir
            src_tools = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools")
            dst_tools = os.path.join(target_dir, "tools")
            if os.path.exists(src_tools) and os.path.normcase(src_tools) != os.path.normcase(dst_tools):
                shutil.copytree(src_tools, dst_tools, dirs_exist_ok=True)
                print(f"[Instalador] Pasta tools copiada para: {dst_tools}")

            # Configura início automático com o Windows
            cls.set_autostart(enable=True, custom_path=target_exe)

            # Verifica driver ViGEmBus
            if not check_vigem_driver():
                msi = get_vigem_msi_path()
                if msi:
                    install_vigem_driver_elevation(msi)

            return True
        except Exception as e:
            print(f"[Instalador] Erro na instalação: {e}")
            return False

    @classmethod
    def uninstall_self(cls) -> bool:
        cls.set_autostart(False)
        print("[Desinstalador] Auto-inicialização removida com sucesso.")
        return True


# ==============================================================================
# 8. GERENCIADOR DE INSTÂNCIA ÚNICA (WINDOWS NAMED MUTEX)
# ==============================================================================

class SingleInstance:
    """Garante que apenas uma instância da Bridge rode em segundo plano."""
    MUTEX_NAME = "Global\\FUAG_MobileControllerBridge_Mutex"

    def __init__(self):
        self.mutex = None
        self.already_running = False
        try:
            kernel32 = ctypes.windll.kernel32
            self.mutex = kernel32.CreateMutexW(None, False, self.MUTEX_NAME)
            ERROR_ALREADY_EXISTS = 183
            if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
                self.already_running = True
        except Exception:
            self.already_running = False

    def close(self):
        if self.mutex:
            try:
                ctypes.windll.kernel32.CloseHandle(self.mutex)
            except Exception:
                pass
            self.mutex = None


# ==============================================================================
# 9. SERVIÇO EM SEGUNDO PLANO COM ÍCONE NA BANDEJA (SYSTEM TRAY)
# ==============================================================================

class BackgroundTrayApp:
    """Roda 100% em segundo plano na barra de tarefas, com indicador visual CONECTADO."""
    def __init__(self, hub: ControllerBridgeHub):
        self.hub = hub
        self.icon = None
        self._last_connected = False
        self._gui_window = None
        
        # Conecta listener de eventos do hub
        self.hub.on_connection_change = self._on_connection_change

    def _create_icon_image(self, connected: bool):
        from PIL import Image, ImageDraw
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Cor de fundo e destaque
        bg_color = (22, 163, 74, 255) if connected else (51, 65, 85, 255)
        draw.ellipse((4, 4, 60, 60), fill=bg_color)
        draw.rounded_rectangle((12, 20, 52, 44), radius=8, fill=(18, 19, 28, 255))

        if connected:
            # Verde neon conectado
            draw.ellipse((16, 26, 26, 36), fill=(0, 255, 102, 255))
            draw.ellipse((38, 26, 48, 36), fill=(0, 255, 102, 255))
            draw.ellipse((29, 23, 35, 29), fill=(0, 255, 102, 255))
        else:
            # Amarelo/cinza aguardando
            draw.ellipse((16, 26, 26, 36), fill=(234, 179, 8, 255))
            draw.ellipse((38, 26, 48, 36), fill=(148, 163, 184, 255))
            draw.ellipse((29, 23, 35, 29), fill=(234, 179, 8, 255))

        return img

    def _on_connection_change(self, is_connected: bool, proto: str, device: str):
        if is_connected == self._last_connected:
            return
        self._last_connected = is_connected

        if self.icon:
            self.icon.icon = self._create_icon_image(is_connected)
            if is_connected:
                self.icon.title = f"🎮 FUAG Bridge: CONECTADO! ({proto}) | {device}"
                try:
                    self.icon.notify(
                        f"Smartphone conectado via {proto}!\nPronto para jogar e traduzir comandos.",
                        "🎮 FUAG Bridge Conectado"
                    )
                except Exception:
                    pass
                self._show_floating_toast(f"🟢 FUAG BRIDGE CONECTADO ({proto})")
            else:
                self.icon.title = "🎮 FUAG Bridge: Aguardando celular... (Porta 5000)"
                try:
                    self.icon.notify("Smartphone desconectado.\nAguardando reconexão...", "🎮 FUAG Bridge")
                except Exception:
                    pass

    def _show_floating_toast(self, text: str):
        def _run():
            try:
                import tkinter as tk
                root = tk.Tk()
                root.overrideredirect(True)
                root.attributes("-topmost", True)
                root.attributes("-alpha", 0.94)
                root.configure(bg="#0E1017")
                sw = root.winfo_screenwidth()
                sh = root.winfo_screenheight()
                w, h = 330, 60
                x = sw - w - 24
                y = sh - h - 60
                root.geometry(f"{w}x{h}+{x}+{y}")
                frame = tk.Frame(root, bg="#161824", highlightthickness=2, highlightbackground="#00FF66")
                frame.pack(fill="both", expand=True)
                tk.Label(frame, text="🎮 FUAG MOBILE CONTROLLER", fg="#00E5FF", bg="#161824", font=("Segoe UI", 9, "bold")).pack(anchor="w", padx=12, pady=(6, 0))
                tk.Label(frame, text=text, fg="#00FF66", bg="#161824", font=("Segoe UI", 11, "bold")).pack(anchor="w", padx=12, pady=(2, 6))
                root.after(2600, root.destroy)
                root.mainloop()
            except Exception:
                pass
        threading.Thread(target=_run, daemon=True).start()

    def _open_gui(self):
        def _launch():
            try:
                app = ModernBridgeGUI(self.hub, standalone=False)
                app.run()
            except Exception as e:
                print(f"[Tray] Erro ao abrir GUI: {e}")
        threading.Thread(target=_launch, daemon=True).start()

    def _build_menu(self):
        import pystray

        def is_mode(m):
            return lambda item: self.hub.active_mode == m

        def set_mode(m):
            def _action(icon, item):
                self.hub.set_mode(m)
            return _action

        def toggle_autostart(icon, item):
            curr = WindowsAutostart.is_autostart_enabled()
            WindowsAutostart.set_autostart(not curr)

        def open_gui(icon, item):
            self._open_gui()

        def install_driver(icon, item):
            msi = get_vigem_msi_path()
            if msi:
                install_vigem_driver_elevation(msi)

        def exit_app(icon, item):
            self.hub.stop()
            icon.stop()

        return pystray.Menu(
            pystray.MenuItem(lambda item: f"Status: {'🟢 CONECTADO' if self.hub.network.is_receiving else '🟡 AGUARDANDO CELULAR'}", None, enabled=False),
            pystray.MenuItem(lambda item: f"📱 USB: {self.hub.adb.device_name}", None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("⌨️ Teclado DirectInput (WASD)", set_mode("keyboard"), checked=is_mode("keyboard"), radio=True),
            pystray.MenuItem("🎮 Controle Xbox 360 (XInput)", set_mode("xbox"), checked=is_mode("xbox"), radio=True),
            pystray.MenuItem("🎮 Controle PlayStation 4 (DS4)", set_mode("ps4"), checked=is_mode("ps4"), radio=True),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("🚀 Iniciar com o Windows", toggle_autostart, checked=lambda item: WindowsAutostart.is_autostart_enabled()),
            pystray.MenuItem("📦 Instalar Driver ViGEmBus", install_driver),
            pystray.MenuItem("⚙️ Abrir Painel de Calibração", open_gui),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("❌ Sair da Bridge", exit_app)
        )

    def run(self):
        import pystray
        self.hub.start()

        # Garante auto-início configurado no Windows
        if not WindowsAutostart.is_autostart_enabled():
            WindowsAutostart.set_autostart(True)

        self.icon = pystray.Icon(
            "FUAG_Bridge",
            self._create_icon_image(False),
            "🎮 FUAG Bridge: Aguardando celular... (Porta 5000)",
            menu=self._build_menu()
        )
        print("[Bridge] Executando em segundo plano na barra de tarefas (System Tray).")
        self.icon.run()


# ==============================================================================
# 10. MODO CONSOLE (HEADLESS)
# ==============================================================================

def run_console_mode(hub: ControllerBridgeHub):
    print("=" * 60)
    print("🎮 MOBILE CONTROLLER BRIDGE (Modo Console)")
    print("=" * 60)
    attach_thread_to_input_desktop()
    hub.start()
    print(f"[*] Modo ativo: {hub.active_mode.upper()} | Bluetooth RFCOMM: {'Canal ' + str(hub.network.bt_channel) if hub.network.bluetooth_available else 'Desativado'}")
    print("[*] Pressione Ctrl+C para encerrar.")
    try:
        while True:
            time.sleep(0.4)
            p = hub.current_payload
            rec = f"ONLINE ({hub.network.active_protocol})" if hub.network.is_receiving else "OFFLINE"
            if p.get("modo") == "fps":
                dx = int(p.get("mouse_dx", 0))
                dy = int(p.get("mouse_dy", 0))
                fire = "TIRO" if p.get("disparo") else "-"
                zoom = "ZOOM" if p.get("zoom") else "-"
                rel = "RELOAD" if p.get("recarregar") else "-"
                grip = "DUPLA" if p.get("empunhadura_dupla") else "SOLO"
                print(f"\r[Status: {rec}] FPS: dx={dx:+4d}, dy={dy:+4d} | [{fire}] [{zoom}] [{rel}] [{grip}] | Pacotes: {hub.network.packets_count:6d} ", end="")
            elif p.get("modo") in ("luta", "fight"):
                atk = "SOCO [C]" if p.get("ataque") else "-"
                defe = "DEFESA [V]" if p.get("defesa") else "-"
                esq = "ESQ [A]" if p.get("esquerda") else "-"
                dir_ = "DIR [D]" if p.get("direita") else "-"
                jmp = "PULO [W]" if p.get("pular") else "-"
                print(f"\r[Status: {rec}] LUTA: [{atk}] [{defe}] [{esq}] [{dir_}] [{jmp}] | Pacotes: {hub.network.packets_count:6d} ", end="")
            else:
                ang = p.get("angulo", 0.0)
                print(f"\r[Status: {rec}] Volante: {ang:+5.1f}° | Pacotes: {hub.network.packets_count:6d} | USB: {hub.adb.device_name[:20]} ", end="")
    except KeyboardInterrupt:
        print("\n[*] Encerrando...")
    finally:
        hub.stop()


# ==============================================================================
# 11. PONTO DE ENTRADA PRINCIPAL
# ==============================================================================

if __name__ == "__main__":
    # 1. Comandos de instalação / desinstalação
    if "--install" in sys.argv:
        print("[*] Instalando FUAG Mobile Controller Bridge...")
        ok = WindowsAutostart.install_self()
        if ok:
            print("[OK] Instalação concluída com sucesso! Iniciará com o Windows.")
            target_exe = WindowsAutostart.get_installed_exe_path()
            if os.path.exists(target_exe) and target_exe.lower().endswith(".exe"):
                try:
                    subprocess.Popen([target_exe, "--background"])
                except Exception as err:
                    print(f"[!] Info ao iniciar: {err}")
        else:
            print("[ERRO] Falha ao instalar.")
        sys.exit(0)

    if "--uninstall" in sys.argv:
        print("[*] Desinstalando FUAG Mobile Controller Bridge...")
        WindowsAutostart.uninstall_self()
        sys.exit(0)

    # 2. Verificação de Instância Única (Named Mutex)
    single = SingleInstance()
    if single.already_running:
        if "--background" in sys.argv or "--tray" in sys.argv:
            # Já está rodando silenciosamente, encerra sem duplicar
            sys.exit(0)
        else:
            try:
                import tkinter as tk
                from tkinter import messagebox
                r = tk.Tk()
                r.withdraw()
                messagebox.showinfo(
                    "FUAG Mobile Controller",
                    "A Bridge já está em execução em segundo plano na barra de tarefas (junto ao relógio do Windows)!\n\n"
                    "Basta abrir o aplicativo no smartphone para conectar e jogar."
                )
                r.destroy()
            except Exception:
                print("[*] A Bridge já está em execução em segundo plano.")
            sys.exit(0)

    hub = ControllerBridgeHub()

    # 3. Modos de execução
    if "--console" in sys.argv:
        run_console_mode(hub)
    elif "--gui" in sys.argv:
        app = ModernBridgeGUI(hub, standalone=True)
        app.run()
    else:
        # Padrão: Modo Segundo Plano (System Tray) com expressão visual CONECTADO
        tray_app = BackgroundTrayApp(hub)
        tray_app.run()
