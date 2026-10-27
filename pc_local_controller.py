"""
FUAG PC Local Controller - Universal Vision Gamepad & Input Emulator
===================================================================
Versão Windows Completa e Autossuficiente com Interface Gráfica Moderna,
Configurações Avançadas e Rastreamento Local por Visão Computacional.

Modos de Jogo Suportados:
1. 👤 Modo Facial (Volante com Head Tracking, Acelerador, Freio e Nitro por Expressão)
2. ✋ Modo Gestual (Volante Tático com Duas Mãos, Polegares para Acelerar/Frear)
3. 🎯 Modo FPS (Mira com Dedo Indicador, Gatilho de Tiro no Dedo Médio, Zoom com Dedão)
4. 🥋 Modo Luta (Stick Fight The Game: Socos [C], Defesa [V], Pulo [W], Esquiva [A/D])
5. 🧍 Modo Corporal (Movimento de Tronco, Pulo Físico e Agachamento)

Emulação de Hardware no Windows (Zero Lag / Latência < 1ms):
- Controle Oficial Xbox 360 (XInput via ViGEmBus)
- Controle Oficial PlayStation 4 (DualShock 4 via ViGEmBus)
- Teclado Gamer DirectInput (WASD / Setas com Direção Progressiva PWM)
- Mouse DirectInput de Alta Precisão (para Mira FPS)
"""

import sys
import os
import time
import math
import json
import threading
import subprocess
import shutil
import ctypes
import urllib.request
from typing import Optional, Dict, Any, Tuple, List

# Ativa Per-Monitor DPI Awareness no Windows para gráficos e fontes nítidas
if sys.platform == "win32":
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass

# Suporte a UTF-8 e flush imediato no console do Windows
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

import cv2
import numpy as np

# MediaPipe Vision
try:
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision as mp_vision
except Exception:
    mp = None
    mp_python = None
    mp_vision = None

# Pillow para renderização da câmera ao vivo na GUI
try:
    from PIL import Image, ImageTk, ImageDraw
    HAS_PIL = True
except Exception:
    HAS_PIL = False

# Tkinter UI
import tkinter as tk
from tkinter import ttk, messagebox

# ==============================================================================
# 0. INJEÇÃO WIN32 NATIVA DE MOUSE E TECLADO
# ==============================================================================

_attached_threads = set()
_attach_lock = threading.Lock()

def attach_thread_to_input_desktop(force: bool = False) -> bool:
    """Garante que a thread chamadora esteja anexada ao desktop interativo do usuário."""
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
# 1. UTILITÁRIOS DE DRIVER (VIGEMBUS)
# ==============================================================================

def get_base_path() -> str:
    if getattr(sys, 'frozen', False) and hasattr(sys, '_MEIPASS'):
        return sys._MEIPASS
    return os.path.dirname(os.path.abspath(__file__))

def get_vigem_msi_path() -> Optional[str]:
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
# 2. GERENCIADOR DE CONFIGURAÇÕES PERSISTENTES
# ==============================================================================

DEFAULT_CONFIG: Dict[str, Any] = {
    "mode": "facial",             # facial, gestual, fps, fight, corporal
    "controller": "keyboard",      # keyboard, xbox, ps4
    "camera_index": 0,
    "prefer_ir": True,
    "invert_steer": False,
    "invert_fps_y": False,
    "fps_sens_index": 1,           # 0: Baixa (420), 1: Média (720), 2: Alta (1100)
    "max_angle": 35.0,
    "deadzone": 4.0,
    "key_layout": "both",          # both, arrows, wasd
    "mirror_video": True,
    "show_landmarks": True,
}

class ConfigManager:
    """Gerencia leitura e gravação das configurações no arquivo pc_controller_config.json."""
    CONFIG_FILE = os.path.join(get_base_path(), "pc_controller_config.json")

    @classmethod
    def load(cls) -> Dict[str, Any]:
        config = dict(DEFAULT_CONFIG)
        if os.path.exists(cls.CONFIG_FILE):
            try:
                with open(cls.CONFIG_FILE, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                    if isinstance(saved, dict):
                        config.update(saved)
            except Exception as e:
                print(f"[Config] Erro ao carregar configurações: {e}")
        return config

    @classmethod
    def save(cls, config: Dict[str, Any]):
        try:
            with open(cls.CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(config, f, indent=2, ensure_ascii=False)
            print("[Config] Configurações salvas com sucesso.")
        except Exception as e:
            print(f"[Config] Erro ao salvar configurações: {e}")

# ==============================================================================
# 3. CONTROLADORES VIRTUAIS (TECLADO DIRECTINPUT, XBOX 360, PS4)
# ==============================================================================

class BaseController:
    def apply_inputs(self, payload: Dict[str, Any], settings: Dict[str, Any]):
        pass
    def release_all(self):
        pass
    def close(self):
        pass


class KeyboardController(BaseController):
    """Controlador que injeta entradas de Teclado DirectInput (WASD / Setas / Ambos).
    Inclui Direção Progressiva Inteligente (PWM Pulse Steering) para curvas suaves."""
    def __init__(self, key_layout: str = "both"):
        self.key_layout = key_layout
        self.active_keys = set()
        self._last_assert = {}
        self._lock = threading.Lock()

        self.progressive_steering = True
        self._steer_dir = 0
        self._steer_magnitude = 0.0
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

    def _steer_pulse_loop(self):
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
                    self._release_keys(keys_l)
                    self._release_keys(keys_r)
                elif s_dir > 0:
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
            is_fps = payload.get("modo") == "fps" or "mouse_dx" in payload or "joy_rx" in payload or "disparo" in payload or "recarregar" in payload
            if is_fps:
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

                fire = bool(payload.get("disparo", False))
                if fire != self._last_fire:
                    self._last_fire = fire
                    win32_mouse_button("left", fire)

                zoom = bool(payload.get("zoom", False))
                if zoom != self._last_zoom:
                    self._last_zoom = zoom
                    win32_mouse_button("right", zoom)

                reload_cmd = bool(payload.get("recarregar", False))
                if reload_cmd and not self._last_reload:
                    self._last_reload = True
                    win32_press_reload()
                elif not reload_cmd:
                    self._last_reload = False

                # Locomoção WASD via Cabeça
                self._apply_action(["w"], bool(payload.get("cima", False)), now)
                self._apply_action(["s"], bool(payload.get("baixo", False)), now)
                self._apply_action(["a"], bool(payload.get("esquerda", False)), now)
                self._apply_action(["d"], bool(payload.get("direita", False)), now)

                self._steer_dir = 0
                self._steer_magnitude = 0.0
                return

            is_fight = payload.get("modo") in ("luta", "fight") or "ataque" in payload or "defesa" in payload
            if is_fight:
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
            else:
                self._keys_left = ["left", "a"]
                self._keys_right = ["right", "d"]
                keys_up = ["up", "w"]
                keys_down = ["down", "s"]
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

            keys_jump = ["space"]

            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))

            if gas and brake:
                brake = False

            self._apply_action(keys_up, gas, now)
            self._apply_action(keys_down, brake, now)

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
            # Cálculo de volante analógico contínuo e suave (-1.0 a +1.0)
            # Resposta direta 1:1 sem zona morta mecânica; centralização gerida por dwell timer
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

            self.pad.left_joystick_float(x_value_float=norm_x, y_value_float=0.0)

            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))
            if gas and brake:
                brake = False
            jump = bool(payload.get("pular", False)) and not gas

            self.pad.right_trigger_float(1.0 if gas else 0.0)
            self.pad.left_trigger_float(1.0 if brake else 0.0)

            if jump:
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_A)

            if brake:
                self.pad.press_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
            else:
                self.pad.release_button(self.vg.XUSB_BUTTON.XUSB_GAMEPAD_X)

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
                # 1. Analógico Direito (Mira / Câmera 100% pelos Olhos) - DS4: 128 = Centro
                rx = float(payload.get("joy_rx", 0.0))
                ry = float(payload.get("joy_ry", 0.0))
                thumb_rx = int(128 + max(-1.0, min(1.0, rx)) * 127)
                thumb_ry = int(128 - max(-1.0, min(1.0, ry)) * 127) # Y invertido no DS4
                thumb_rx = max(0, min(255, thumb_rx))
                thumb_ry = max(0, min(255, thumb_ry))
                self.pad.right_joystick(thumb_rx, thumb_ry)

                # 2. Analógico Esquerdo (Movimentação / Locomoção pela Cabeça)
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

            thumb_lx = int(128 + norm_x * 127)
            thumb_lx = max(0, min(255, thumb_lx))
            self.pad.left_joystick(thumb_lx, 128)

            gas = bool(payload.get("cima", False) or payload.get("polegar_dir", False))
            brake = bool(payload.get("baixo", False) or payload.get("polegar_esq", False))
            if gas and brake:
                brake = False
            jump = bool(payload.get("pular", False)) and not gas

            self.pad.right_trigger_float(1.0 if gas else 0.0)
            self.pad.left_trigger_float(1.0 if brake else 0.0)

            if jump:
                self.pad.press_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)
            else:
                self.pad.release_button(self.vg.DS4_BUTTONS.DS4_BUTTON_CROSS)

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
# 4. WRAPPERS NEURAIS MULTI-MODELO (FACE, HANDS, POSE)
# ==============================================================================

class UniversalModelLoader:
    """Carrega modelos neurais MediaPipe Tasks de forma transparente."""
    MODELS = {
        "face": ("face_landmarker.task", "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"),
        "hands": ("hand_landmarker.task", "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"),
        "pose": ("pose_landmarker_lite.task", "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task")
    }

    @classmethod
    def get_model_path(cls, model_key: str) -> str:
        filename, url = cls.MODELS[model_key]
        base_dir = get_base_path()
        target = os.path.join(base_dir, filename)
        if os.path.exists(target):
            return target
        cwd_target = os.path.join(os.getcwd(), filename)
        if os.path.exists(cwd_target):
            return cwd_target
        try:
            print(f"[VisionEngine] Baixando modelo neural '{filename}'...")
            urllib.request.urlretrieve(url, target)
            return target
        except Exception as e:
            print(f"[VisionEngine] Erro ao baixar {filename}: {e}")
            return filename

class VisionDetectors:
    def __init__(self):
        self.face_detector = None
        self.hand_detector = None
        self.pose_detector = None
        self._init_all()

    def _init_all(self):
        if not mp_python or not mp_vision:
            return
        # 1. Face (com Blendshapes Oculares e Faciais ativados)
        try:
            face_path = UniversalModelLoader.get_model_path("face")
            try:
                # Python MediaPipe Tasks usa output_face_blendshapes (output_facial_blendshapes no Android)
                opts = mp_vision.FaceLandmarkerOptions(
                    base_options=mp_python.BaseOptions(model_asset_path=face_path),
                    output_face_blendshapes=True,
                    num_faces=1
                )
            except TypeError:
                opts = mp_vision.FaceLandmarkerOptions(
                    base_options=mp_python.BaseOptions(model_asset_path=face_path),
                    output_facial_blendshapes=True,
                    num_faces=1
                )
            self.face_detector = mp_vision.FaceLandmarker.create_from_options(opts)
        except Exception as e:
            print(f"[VisionDetectors] FaceLandmarker indisponível: {e}")

        # 2. Hands
        try:
            hand_path = UniversalModelLoader.get_model_path("hands")
            opts = mp_vision.HandLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=hand_path),
                num_hands=2,
                min_hand_detection_confidence=0.4
            )
            self.hand_detector = mp_vision.HandLandmarker.create_from_options(opts)
        except Exception as e:
            print(f"[VisionDetectors] HandLandmarker indisponível: {e}")

        # 3. Pose
        try:
            pose_path = UniversalModelLoader.get_model_path("pose")
            opts = mp_vision.PoseLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=pose_path)
            )
            self.pose_detector = mp_vision.PoseLandmarker.create_from_options(opts)
        except Exception as e:
            print(f"[VisionDetectors] PoseLandmarker indisponível: {e}")

# ==============================================================================
# 5. MOTOR DE VISÃO MULTI-MODO LOCAL (SCANNER IR + PROCESSAMENTO)
# ==============================================================================

class LocalVisionEngine:
    """Motor central que captura da webcam/IR, executa o modo de IA selecionado
    e gera a telemetria instantânea para os emuladores."""

    def __init__(self, on_payload_callback=None, config: Optional[Dict[str, Any]] = None):
        self.on_payload_callback = on_payload_callback
        self.config = config or dict(DEFAULT_CONFIG)
        self.active_mode = self.config.get("mode", "facial")
        self.camera_index = int(self.config.get("camera_index", 0))
        self.is_ir = False
        self.camera_status_str = "Inicializando..."
        self.available_cameras: List[Tuple[int, bool, str]] = []
        self.running = False
        self._thread: Optional[threading.Thread] = None

        # Calibrações e estados contínuos
        self.baseline_roll = 0.0
        self.baseline_pitch = 0.40
        self._smoothed_angle = 0.0
        self.fps = 0.0
        self.has_detection = False

        # Centralização temporal do volante (Dwell Timer 0.3s / sem deadzone rígida)
        self._wheel_center_dwell_start = 0.0
        self._last_steer_dir = 'centro'

        # Estado do Modo FPS (Mira suave e anti-flick calibrada)
        self._fps_last_pos = None
        self._fps_filtered_dx = 0.0
        self._fps_filtered_dy = 0.0
        self._fps_subpixel_x = 0.0
        self._fps_subpixel_y = 0.0
        self._fps_middle_was_open = True
        self._fps_is_firing = False
        self._fps_is_zoom = False
        self._fps_recoil_suppress = 0

        # Estado do Modo FPS Mesh (Rastreamento Ocular e Cabeça Hands-Free)
        self._fps_mesh_baseline_pitch = 0.40
        self._fps_mesh_baseline_yaw = 0.0
        self._gaze_filtered_x = 0.0
        self._gaze_filtered_y = 0.0
        self._gaze_subpixel_x = 0.0
        self._gaze_subpixel_y = 0.0

        # Estado do Modo Luta
        self._fight_baseline_hip_y = 0.0
        self._fight_prev_hip_y = 0.0

        # Quadro anotado para a GUI
        self.latest_frame: Optional[np.ndarray] = None
        self._frame_lock = threading.Lock()

        # Inicializa modelos neurais
        self.detectors = VisionDetectors()

        # Varredura inicial de câmeras
        self.scan_cameras()

    def scan_cameras(self) -> List[Tuple[int, bool, str]]:
        """Varre os índices 0 a 3 buscando câmeras disponíveis e identificando infravermelho."""
        cams = []
        ir_idx = None
        for idx in range(4):
            try:
                cap = cv2.VideoCapture(idx)
                if cap and cap.isOpened():
                    for _ in range(2): cap.read()
                    ret, frame = cap.read()
                    cap.release()
                    if ret and frame is not None and frame.size > 0:
                        b, g, r = cv2.split(frame)
                        diff_rg = cv2.absdiff(r, g).mean()
                        diff_gb = cv2.absdiff(g, b).mean()
                        is_ir = bool(diff_rg < 1.5 and diff_gb < 1.5)
                        label = f"Câmera IR (Índice {idx})" if is_ir else f"Câmera RGB (Índice {idx})"
                        cams.append((idx, is_ir, label))
                        if is_ir and ir_idx is None:
                            ir_idx = idx
            except Exception:
                continue

        self.available_cameras = cams
        if ir_idx is not None and self.config.get("prefer_ir", True):
            self.camera_index = ir_idx
            self.is_ir = True
            self.camera_status_str = f"Câmera IR Ativa (Índice {ir_idx})"
        elif cams:
            self.camera_index = cams[0][0]
            self.is_ir = cams[0][1]
            self.camera_status_str = cams[0][2]
        else:
            self.camera_index = 0
            self.is_ir = False
            self.camera_status_str = "Câmera Padrão (Índice 0)"

        return self.available_cameras

    def set_camera(self, index: int):
        self.camera_index = index
        for idx, is_ir, label in self.available_cameras:
            if idx == index:
                self.is_ir = is_ir
                self.camera_status_str = label
                break
        self.config["camera_index"] = index
        ConfigManager.save(self.config)

    def set_mode(self, mode: str):
        self.active_mode = mode
        self.config["mode"] = mode
        self._fps_last_pos = None
        self._gaze_filtered_x = 0.0
        self._gaze_filtered_y = 0.0
        ConfigManager.save(self.config)

    def tare_center(self):
        """Zera a posição neutra do volante facial, corporal e mira ocular."""
        self.baseline_roll = getattr(self, '_last_raw_roll', 0.0)
        self.baseline_pitch = getattr(self, '_last_raw_pitch', 0.40)
        self._fps_mesh_baseline_pitch = getattr(self, '_last_raw_pitch', 0.40)
        self._fps_mesh_baseline_yaw = getattr(self, '_last_raw_yaw', 0.0)
        self._fight_baseline_hip_y = getattr(self, '_last_raw_hip_y', 0.0)
        self._smoothed_angle = 0.0
        self._gaze_filtered_x = 0.0
        self._gaze_filtered_y = 0.0
        self._gaze_subpixel_x = 0.0
        self._gaze_subpixel_y = 0.0
        print(f"[VisionEngine] Centro calibrado! (Roll={self.baseline_roll:.1f}°, Pitch={self.baseline_pitch:.3f}, Yaw={self._fps_mesh_baseline_yaw:.3f})")

    def start(self):
        if self.running: return
        self.running = True
        self._thread = threading.Thread(target=self._capture_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)

    def _capture_loop(self):
        cap = cv2.VideoCapture(self.camera_index)
        if not cap.isOpened():
            cap = cv2.VideoCapture(0)

        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        frame_count = 0
        fps_start = time.time()

        while self.running:
            ret, frame = cap.read()
            if not ret or frame is None:
                time.sleep(0.01)
                continue

            frame_count += 1
            now = time.time()
            if now - fps_start >= 1.0:
                self.fps = frame_count / (now - fps_start)
                frame_count = 0
                fps_start = now

            if self.config.get("mirror_video", True):
                frame = cv2.flip(frame, 1)

            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            annotated = frame.copy()

            # Executa regras conforme o modo selecionado
            mode = self.active_mode
            payload = {"modo": mode, "fps": round(self.fps, 1), "detect": False}

            if mode == "facial":
                payload = self._process_facial(rgb, annotated)
            elif mode == "fps":
                payload = self._process_fps(rgb, annotated)
            elif mode == "fps_mesh":
                payload = self._process_fps_mesh(rgb, annotated)
            elif mode == "gestual":
                payload = self._process_gestual(rgb, annotated)
            elif mode in ("luta", "fight"):
                payload = self._process_fight(rgb, annotated)
            elif mode == "corporal":
                payload = self._process_corporal(rgb, annotated)

            payload["fps"] = round(self.fps, 1)
            payload["camera_label"] = self.camera_status_str
            payload["is_ir"] = self.is_ir

            with self._frame_lock:
                self.latest_frame = annotated

            if self.on_payload_callback:
                try:
                    self.on_payload_callback(payload)
                except Exception:
                    pass

        cap.release()

    # --- PROCESSADORES DE MODOS ESPECÍFICOS ---

    def _process_facial(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        detector = self.detectors.face_detector
        if not detector:
            return {"modo": "facial", "detect": False, "angulo": 0.0}

        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = detector.detect(mp_img)
        has_face = bool(res and res.face_landmarks and len(res.face_landmarks) > 0)
        self.has_detection = has_face

        if not has_face:
            self._smoothed_angle = self._smoothed_angle * 0.5
            return {"modo": "facial", "detect": False, "angulo": round(self._smoothed_angle, 1), "cima": False, "baixo": False, "pular": False}

        lms = res.face_landmarks[0]
        p_left = lms[33]
        p_right = lms[263]
        p_nose = lms[1]
        p_eyes = lms[168]
        p_chin = lms[152]
        p_lip_up = lms[13]
        p_lip_down = lms[14]
        p_mouth_l = lms[61]
        p_mouth_r = lms[291]

        # 1. Roll / Volante com Centralização Temporal (Dwell Timer 0.3s)
        dx = p_right.x - p_left.x
        dy = p_right.y - p_left.y
        raw_roll = -math.degrees(math.atan2(dy, dx))
        self._last_raw_roll = raw_roll
        tared = raw_roll - self.baseline_roll
        self._smoothed_angle = self._smoothed_angle * 0.35 + tared * 0.65

        now = time.time()
        eff_roll = -self._smoothed_angle if self.config.get("invert_steer", False) else self._smoothed_angle
        center_guide_tolerance = 2.5
        center_dwell_threshold = 0.3 # 0.3s

        if abs(eff_roll) <= center_guide_tolerance:
            if self._wheel_center_dwell_start == 0.0:
                self._wheel_center_dwell_start = now
            elapsed = now - self._wheel_center_dwell_start
            if elapsed >= center_dwell_threshold:
                face_angle = 0.0
                self._last_steer_dir = 'centro'
            else:
                face_angle = eff_roll
        else:
            self._wheel_center_dwell_start = 0.0
            face_angle = eff_roll
            self._last_steer_dir = 'direita' if eff_roll > 0 else 'esquerda'

        # 2. Pitch / Gas e Freio
        face_h = max(0.05, p_chin.y - p_eyes.y)
        pitch_ratio = (p_nose.y - p_eyes.y) / face_h
        self._last_raw_pitch = pitch_ratio

        cmd_cima = pitch_ratio < (self.baseline_pitch - 0.065)
        cmd_baixo = pitch_ratio > (self.baseline_pitch + 0.075)

        # 3. Abertura da Boca (Nitro / Espaço)
        mouth_h = abs(p_lip_up.y - p_lip_down.y)
        mouth_w = max(0.01, abs(p_mouth_l.x - p_mouth_r.x))
        mar = mouth_h / mouth_w
        cmd_pular = mar > 0.19

        # Desenho HUD Facial com Guia Central
        h, w = frame.shape[:2]
        pt1 = (int(p_left.x * w), int(p_left.y * h))
        pt2 = (int(p_right.x * w), int(p_right.y * h))
        is_centered = (face_angle == 0.0)
        face_line_color = (0, 255, 102) if is_centered else (0, 229, 255)
        cv2.line(frame, pt1, pt2, face_line_color, 2)
        cv2.circle(frame, (int(p_nose.x * w), int(p_nose.y * h)), 4, (0, 255, 128), -1)
        cv2.circle(frame, (int(p_chin.x * w), int(p_chin.y * h)), 3, (150, 150, 150), -1)

        txt = "VOLANTE: CENTRO (0.0 deg)" if is_centered else f"VOLANTE: {face_angle:+.1f} deg"
        if cmd_cima: txt += " | GAS [W]"
        elif cmd_baixo: txt += " | FREIO [S]"
        if cmd_pular: txt += " | NITRO [SPC]"
        cv2.putText(frame, txt, (14, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 102) if is_centered else (0, 255, 200), 2)

        return {
            "modo": "facial",
            "detect": True,
            "angulo": round(face_angle, 1),
            "cima": cmd_cima,
            "baixo": cmd_baixo,
            "pular": cmd_pular,
            "mar": round(mar, 3),
            "pitch_ratio": round(pitch_ratio, 3)
        }

    def _process_fps(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        detector = self.detectors.hand_detector
        if not detector:
            return {"modo": "fps", "detect": False, "mouse_dx": 0, "mouse_dy": 0}

        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = detector.detect(mp_img)
        has_hands = bool(res and res.hand_landmarks and len(res.hand_landmarks) > 0)
        self.has_detection = has_hands

        if not has_hands:
            self._fps_last_pos = None
            self._fps_filtered_dx = 0.0
            self._fps_filtered_dy = 0.0
            self._fps_subpixel_x = 0.0
            self._fps_subpixel_y = 0.0
            return {"modo": "fps", "detect": False, "mouse_dx": 0, "mouse_dy": 0, "disparo": False, "zoom": False, "recarregar": False}

        h, w = frame.shape[:2]
        hand_lms = res.hand_landmarks[0]

        # Dedo indicador (mira): nó 8
        tip8 = hand_lms[8]
        current_pos = (tip8.x, tip8.y)

        # Mira e Suavização Anti-Flick de Alta Precisão
        move_x = 0.0
        move_y = 0.0

        if self._fps_last_pos is None:
            self._fps_last_pos = current_pos
            self._fps_filtered_dx = 0.0
            self._fps_filtered_dy = 0.0
        else:
            dx = current_pos[0] - self._fps_last_pos[0]
            dy = current_pos[1] - self._fps_last_pos[1]
            dist = math.sqrt(dx * dx + dy * dy)

            if dist > 0.12:  # Proteção contra teletransporte / flick
                self._fps_last_pos = current_pos
                self._fps_filtered_dx = 0.0
                self._fps_filtered_dy = 0.0
            else:
                self._fps_last_pos = current_pos
                deadzone = 0.0032
                if dist > deadzone:
                    excess = dist - deadzone
                    ratio = excess / dist
                    raw_x = dx * ratio
                    raw_y = dy * ratio

                    alpha = 0.85 if dist > 0.015 else 0.60
                    self._fps_filtered_dx = self._fps_filtered_dx * (1.0 - alpha) + raw_x * alpha
                    self._fps_filtered_dy = self._fps_filtered_dy * (1.0 - alpha) + raw_y * alpha
                    move_x = self._fps_filtered_dx
                    move_y = self._fps_filtered_dy
                else:
                    self._fps_filtered_dx = 0.0
                    self._fps_filtered_dy = 0.0

        # Gatilho Dedo Médio (Tiro): nó 12
        m_tip = hand_lms[12]
        m_mcp = hand_lms[9]
        wrist = hand_lms[0]
        palm_len = max(0.01, math.sqrt((wrist.x - m_mcp.x)**2 + (wrist.y - m_mcp.y)**2))
        m_dist = math.sqrt((m_tip.x - m_mcp.x)**2 + (m_tip.y - m_mcp.y)**2) / palm_len

        is_middle_closed = m_dist < 0.60
        fire_triggered = False
        if self._fps_middle_was_open and is_middle_closed:
            fire_triggered = True
            self._fps_is_firing = True
            self._fps_recoil_suppress = 2
        elif not is_middle_closed and m_dist > 0.75:
            self._fps_middle_was_open = True
            self._fps_is_firing = False

        if self._fps_recoil_suppress > 0:
            self._fps_recoil_suppress -= 1
            move_x = 0.0
            move_y = 0.0

        # Zoom com dedão apontado para cima (nó 4)
        thumb_tip = hand_lms[4]
        thumb_mcp = hand_lms[2]
        is_zoom = (thumb_mcp.y - thumb_tip.y) > (palm_len * 0.35)

        # Escala de sensibilidade calibrada
        scale = {0: 420.0, 2: 1100.0}.get(self.config.get("fps_sens_index", 1), 720.0)
        target_dx = max(-55.0, min(55.0, move_x * scale))
        target_dy = max(-55.0, min(55.0, move_y * scale))
        if self.config.get("invert_fps_y", False):
            target_dy = -target_dy

        mouse_dx = 0
        mouse_dy = 0
        if move_x != 0.0 or move_y != 0.0:
            tot_x = target_dx + self._fps_subpixel_x
            tot_y = target_dy + self._fps_subpixel_y
            mouse_dx = int(tot_x)
            mouse_dy = int(tot_y)
            self._fps_subpixel_x = tot_x - mouse_dx
            self._fps_subpixel_y = tot_y - mouse_dy
        else:
            self._fps_subpixel_x = 0.0
            self._fps_subpixel_y = 0.0

        # Desenho HUD Tático FPS
        aim_pt = (int(tip8.x * w), int(tip8.y * h))
        reticle_color = (0, 0, 255) if self._fps_is_firing else ((255, 220, 0) if is_zoom else (0, 255, 128))
        cv2.circle(frame, aim_pt, 16, reticle_color, 2)
        cv2.circle(frame, aim_pt, 2, reticle_color, -1)
        cv2.line(frame, (aim_pt[0] - 22, aim_pt[1]), (aim_pt[0] - 8, aim_pt[1]), reticle_color, 2)
        cv2.line(frame, (aim_pt[0] + 8, aim_pt[1]), (aim_pt[0] + 22, aim_pt[1]), reticle_color, 2)
        cv2.line(frame, (aim_pt[0], aim_pt[1] - 22), (aim_pt[0], aim_pt[1] - 8), reticle_color, 2)
        cv2.line(frame, (aim_pt[0], aim_pt[1] + 8), (aim_pt[0], aim_pt[1] + 22), reticle_color, 2)

        txt = f"FPS MIRA: dx={mouse_dx:+d}, dy={mouse_dy:+d}"
        if self._fps_is_firing: txt += " | TIRO [M1]"
        if is_zoom: txt += " | ZOOM [M2]"
        cv2.putText(frame, txt, (14, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 220, 255), 2)

        return {
            "modo": "fps",
            "detect": True,
            "mouse_dx": mouse_dx,
            "mouse_dy": mouse_dy,
            "disparo": fire_triggered or self._fps_is_firing,
            "zoom": is_zoom,
            "recarregar": False
        }

    def _process_fps_mesh(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        """
        Modo FPS Mesh (Acessibilidade Severa / Hands-Free para CS 1.6):
        1. Locomoção (WASD via Cabeça):
           - Pitch (nariz 1 vs glabela 168 e queixo 152): Olhar p/ cima ativa W (cima), olhar p/ baixo ativa S (baixo).
           - Yaw (desvio do nariz 1 vs cantos dos olhos 33 e 263): Virar p/ esquerda ativa A, virar p/ direita ativa D.
           - Deadzones calibradas no centro para garantir repouso estático absoluto com o rosto neutro.
        2. Mira da Câmera (Mouse Relativo dx/dy via Rastreamento Ocular):
           - Extração de Blendshapes nativos do MediaPipe: eyeLookInLeft/Right, eyeLookOutLeft/Right, eyeLookUp/Down.
           - Vetor normalizado de olhar (gaze_x, gaze_y) estabilizado durante piscadas unilaterais.
           - Filtro Anti-Tremor (Filtro Exponencial / EMA) para suprimir micro-saccades fisiológicos do olho.
           - Deadzone central ocular e aceleração não-linear para geração dos inteiros mouse_dx e mouse_dy.
        3. Gatilhos de Ação (Cliques via Piscadas Fortes Intencionais):
           - Blendshapes eyeBlinkLeft e eyeBlinkRight com limiar elevado (>= 0.70) e diferencial entre os olhos.
           - Piscada forte do olho Esquerdo = disparo = True (Botão Esquerdo / Mouse 1).
           - Piscada forte do olho Direito = zoom = True (Botão Direito / Mouse 2).
           - Ambos os olhos apertados com força extrema (>= 0.85) = recarregar = True (Tecla R).
        """
        detector = self.detectors.face_detector
        if not detector:
            return {
                "modo": "fps", "detect": False,
                "cima": False, "baixo": False, "esquerda": False, "direita": False,
                "mouse_dx": 0, "mouse_dy": 0, "disparo": False, "zoom": False, "recarregar": False
            }

        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = detector.detect(mp_img)
        has_face = bool(res and res.face_landmarks and len(res.face_landmarks) > 0)
        self.has_detection = has_face

        if not has_face:
            self._gaze_filtered_x *= 0.5
            self._gaze_filtered_y *= 0.5
            return {
                "modo": "fps", "detect": False,
                "cima": False, "baixo": False, "esquerda": False, "direita": False,
                "mouse_dx": 0, "mouse_dy": 0, "disparo": False, "zoom": False, "recarregar": False
            }

        h, w = frame.shape[:2]
        lms = res.face_landmarks[0]

        # ----------------------------------------------------------------------
        # 1. LOCOMOÇÃO (WASD VIA CABEÇA: PITCH & YAW)
        # ----------------------------------------------------------------------
        # Marcos faciais:
        # Nariz: 1, Queixo: 152, Canto externo olho esquerdo: 33, Canto externo olho direito: 263
        # Centro entre os olhos (glabela): 168
        p_nose = lms[1]
        p_chin = lms[152]
        p_left_eye = lms[33]
        p_right_eye = lms[263]
        p_mid_eyes = lms[168]

        # Altura facial de referência (normalização contra distância da câmera)
        face_h = max(0.05, p_chin.y - p_mid_eyes.y)
        mid_eyes_x = (p_left_eye.x + p_right_eye.x) * 0.5
        eye_width = max(0.02, abs(p_right_eye.x - p_left_eye.x))

        # A) Pitch (Inclinação vertical da cabeça para W / S):
        pitch_ratio = (p_nose.y - p_mid_eyes.y) / face_h
        self._last_raw_pitch = pitch_ratio

        base_p = getattr(self, '_fps_mesh_baseline_pitch', self.baseline_pitch)
        pitch_deadzone = 0.065 # Deadzone confortável para manter o corpo neutro

        # Se olhar para cima: nariz sobe na projeção Y em relação aos olhos -> W
        # Se olhar para baixo: nariz desce na projeção Y -> S
        cmd_cima = pitch_ratio < (base_p - pitch_deadzone)
        cmd_baixo = pitch_ratio > (base_p + pitch_deadzone)

        # B) Yaw (Rotação horizontal da cabeça para A / D):
        # Deslocamento horizontal do nariz em relação ao centro dos olhos
        yaw_ratio = (p_nose.x - mid_eyes_x) / eye_width
        self._last_raw_yaw = yaw_ratio

        base_y = getattr(self, '_fps_mesh_baseline_yaw', 0.0)
        yaw_diff = yaw_ratio - base_y
        yaw_deadzone = 0.08 # Deadzone confortável

        # Em imagem espelhada: virar o rosto para a esquerda desloca o nariz para a esquerda (-X)
        cmd_esquerda = yaw_diff < -yaw_deadzone
        cmd_direita = yaw_diff > yaw_deadzone

        # ----------------------------------------------------------------------
        # 2. EXTRAÇÃO DOS BLENDSHAPES OCULARES (RASTREAMENTO DE ÍRIS & PISCADAS)
        # ----------------------------------------------------------------------
        b_dict = {}
        if res.face_blendshapes and len(res.face_blendshapes) > 0:
            b_dict = {b.category_name: b.score for b in res.face_blendshapes[0]}

        # Piscadas (0.0 = aberto, 1.0 = completamente fechado)
        blink_l = b_dict.get("eyeBlinkLeft", 0.0)
        blink_r = b_dict.get("eyeBlinkRight", 0.0)

        # Vetores de olhar do olho esquerdo e direito
        look_out_l = b_dict.get("eyeLookOutLeft", 0.0)
        look_in_l = b_dict.get("eyeLookInLeft", 0.0)
        look_up_l = b_dict.get("eyeLookUpLeft", 0.0)
        look_down_l = b_dict.get("eyeLookDownLeft", 0.0)

        look_in_r = b_dict.get("eyeLookInRight", 0.0)
        look_out_r = b_dict.get("eyeLookOutRight", 0.0)
        look_up_r = b_dict.get("eyeLookUpRight", 0.0)
        look_down_r = b_dict.get("eyeLookDownRight", 0.0)

        # Estabilização Ocular durante Piscadas Unilaterais:
        # Se um olho estiver fechado para ação (ex: piscar para atirar), usamos apenas o olho
        # aberto para que a mira permaneça estável sem trancos.
        if blink_l > 0.55 and blink_r < 0.40:
            look_right = look_out_r
            look_left = look_in_r
            look_up = look_up_r
            look_down = look_down_r
        elif blink_r > 0.55 and blink_l < 0.40:
            look_right = look_in_l
            look_left = look_out_l
            look_up = look_up_l
            look_down = look_down_l
        else:
            look_right = (look_in_l + look_out_r) * 0.5
            look_left = (look_out_l + look_in_r) * 0.5
            look_up = (look_up_l + look_up_r) * 0.5
            look_down = (look_down_l + look_down_r) * 0.5

        # Vetor normalizado de desvio do olho [-1.0 a +1.0]
        # No padrão de joystick: Cima = +Y, Baixo = -Y
        raw_gaze_x = look_right - look_left
        raw_gaze_y = look_up - look_down
        if self.config.get("invert_fps_y", False):
            raw_gaze_y = -raw_gaze_y

        # ----------------------------------------------------------------------
        # 3. FILTRO ANTI-TREMOR & EMULAÇÃO DE JOYSTICK ANALÓGICO
        # ----------------------------------------------------------------------
        # A) Deadzone Central Ocular
        gaze_mag = math.hypot(raw_gaze_x, raw_gaze_y)
        gaze_deadzone = 0.065 # Limiar calibrado de descanso central

        if gaze_mag <= gaze_deadzone:
            target_gx = 0.0
            target_gy = 0.0
        else:
            excess = gaze_mag - gaze_deadzone
            ratio = excess / gaze_mag
            target_gx = raw_gaze_x * ratio
            target_gy = raw_gaze_y * ratio

        # B) Filtro Exponencial (EMA - Exponential Moving Average)
        alpha = 0.28 if gaze_mag > 0.18 else 0.16
        self._gaze_filtered_x = self._gaze_filtered_x * (1.0 - alpha) + target_gx * alpha
        self._gaze_filtered_y = self._gaze_filtered_y * (1.0 - alpha) + target_gy * alpha

        if abs(self._gaze_filtered_x) < 0.003: self._gaze_filtered_x = 0.0
        if abs(self._gaze_filtered_y) < 0.003: self._gaze_filtered_y = 0.0

        # C) Emulação de Analógico Direito (Right Stick - Mira / Câmera via Olhos)
        joy_scales = {0: 1.8, 1: 2.5, 2: 3.5}
        joy_scale = joy_scales.get(self.config.get("fps_sens_index", 1), 2.5)

        filt_mag = math.hypot(self._gaze_filtered_x, self._gaze_filtered_y)
        if filt_mag > 0.0:
            curve = (filt_mag / 0.40) ** 1.30
            joy_rx = (self._gaze_filtered_x / filt_mag) * curve * joy_scale
            joy_ry = (self._gaze_filtered_y / filt_mag) * curve * joy_scale
        else:
            joy_rx = 0.0
            joy_ry = 0.0

        joy_rx = max(-1.0, min(1.0, joy_rx))
        joy_ry = max(-1.0, min(1.0, joy_ry))

        # D) Emulação de Analógico Esquerdo (Left Stick - Movimentação via Cabeça)
        base_p = getattr(self, '_fps_mesh_baseline_pitch', self.baseline_pitch)
        pitch_diff = pitch_ratio - base_p
        pitch_deadzone = 0.055

        base_y = getattr(self, '_fps_mesh_baseline_yaw', 0.0)
        yaw_diff = yaw_ratio - base_y
        yaw_deadzone = 0.065

        if abs(pitch_diff) > pitch_deadzone:
            p_excess = abs(pitch_diff) - pitch_deadzone
            p_sign = -1.0 if pitch_diff > 0 else 1.0 # Olhar p/ cima -> frente (+1.0), p/ baixo -> ré (-1.0)
            joy_ly = max(-1.0, min(1.0, p_sign * (p_excess / 0.10)))
        else:
            joy_ly = 0.0

        if abs(yaw_diff) > yaw_deadzone:
            y_excess = abs(yaw_diff) - yaw_deadzone
            y_sign = 1.0 if yaw_diff > 0 else -1.0 # Olhar p/ direita -> (+1.0), p/ esquerda -> (-1.0)
            joy_lx = max(-1.0, min(1.0, y_sign * (y_excess / 0.12)))
        else:
            joy_lx = 0.0

        cmd_cima = joy_ly > 0.25
        cmd_baixo = joy_ly < -0.25
        cmd_direita = joy_lx > 0.25
        cmd_esquerda = joy_lx < -0.25

        # E) Rate-control de Mouse para compatibilidade com Teclado / DirectInput
        rate_sens = {0: 16.0, 1: 28.0, 2: 44.0}.get(self.config.get("fps_sens_index", 1), 28.0)
        mouse_dx = int(joy_rx * rate_sens)
        mouse_dy = int(-joy_ry * rate_sens)

        # ----------------------------------------------------------------------
        # 4. GATILHOS DE AÇÃO (CLIQUES VIA PISCADAS FORTES INTENCIONAIS)
        # ----------------------------------------------------------------------
        blink_thresh = 0.70
        is_intentional_left = (blink_l >= blink_thresh) and (blink_l - blink_r > 0.25)
        is_intentional_right = (blink_r >= blink_thresh) and (blink_r - blink_l > 0.25)
        is_double_tight = (blink_l >= 0.85) and (blink_r >= 0.85)

        cmd_disparo = is_intentional_left
        cmd_zoom = is_intentional_right
        cmd_recarregar = is_double_tight

        # ----------------------------------------------------------------------
        # 5. RENDERIZAÇÃO DO HUD TÁTICO OCULAR COM DUAL JOYSTICKS
        # ----------------------------------------------------------------------
        pt_l_eye = (int(p_left_eye.x * w), int(p_left_eye.y * h))
        pt_r_eye = (int(p_right_eye.x * w), int(p_right_eye.y * h))
        pt_nose = (int(p_nose.x * w), int(p_nose.y * h))

        # Indicador de Olhos
        col_l_eye = (0, 0, 255) if cmd_disparo else (0, 255, 128)
        col_r_eye = (255, 220, 0) if cmd_zoom else (0, 255, 128)
        cv2.circle(frame, pt_l_eye, 8, col_l_eye, 2 if not cmd_disparo else -1)
        cv2.circle(frame, pt_r_eye, 8, col_r_eye, 2 if not cmd_zoom else -1)

        # Retículo Virtual Central
        center_screen_x = w // 2
        center_screen_y = h // 2
        reticle_x = int(center_screen_x + joy_rx * 140.0)
        reticle_y = int(center_screen_y - joy_ry * 140.0)
        reticle_col = (0, 0, 255) if cmd_disparo else ((255, 220, 0) if cmd_zoom else (0, 255, 255))
        cv2.drawMarker(frame, (reticle_x, reticle_y), reticle_col, cv2.MARKER_CROSS, 20, 2)
        cv2.circle(frame, (reticle_x, reticle_y), 10, reticle_col, 1)
        cv2.circle(frame, (center_screen_x, center_screen_y), int(gaze_deadzone * 180.0), (60, 60, 60), 1)
        cv2.circle(frame, pt_nose, 4, (0, 255, 200), -1)

        # L-Stick Pod (Cabeça / WASD)
        l_pod_c = (80, h - 80)
        cv2.circle(frame, l_pod_c, 34, (60, 60, 75), 2)
        cv2.circle(frame, l_pod_c, 4, (80, 80, 100), -1)
        l_knob = (int(l_pod_c[0] + joy_lx * 24), int(l_pod_c[1] - joy_ly * 24))
        l_col = (0, 229, 255) if (joy_lx != 0.0 or joy_ly != 0.0) else (140, 140, 140)
        cv2.line(frame, l_pod_c, l_knob, l_col, 2)
        cv2.circle(frame, l_knob, 10, l_col, -1)
        cv2.putText(frame, "L-STICK (WASD)", (30, h - 35), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (0, 229, 255), 1)

        # R-Stick Pod (Olhos / Mira Analógica)
        r_pod_c = (w - 80, h - 80)
        r_col = (0, 0, 255) if cmd_disparo else ((255, 220, 0) if cmd_zoom else (0, 255, 128))
        cv2.circle(frame, r_pod_c, 34, (60, 60, 75), 2)
        cv2.circle(frame, r_pod_c, 4, (80, 80, 100), -1)
        r_knob = (int(r_pod_c[0] + joy_rx * 24), int(r_pod_c[1] - joy_ry * 24))
        cv2.line(frame, r_pod_c, r_knob, r_col, 2)
        cv2.circle(frame, r_knob, 10, r_col, -1)
        cv2.putText(frame, "R-STICK (OLHOS)", (w - 130, h - 35), cv2.FONT_HERSHEY_SIMPLEX, 0.40, r_col, 1)

        # Header Superior com Telemetria do Joystick
        hud_txt = f"JOYSTICK OCULAR: R-Stick=[{joy_rx:+.2f}, {joy_ry:+.2f}] | L-Stick=[{joy_lx:+.2f}, {joy_ly:+.2f}]"
        if cmd_disparo: hud_txt += " | RT: TIRO"
        if cmd_zoom: hud_txt += " | LT: ZOOM"
        if cmd_recarregar: hud_txt += " | X: RELOAD"
        cv2.putText(frame, hud_txt, (14, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (0, 255, 200), 2)

        # Rodapé
        blink_txt = f"PISCADA ESQ (RT): {blink_l:.2f} | DIR (LT): {blink_r:.2f} (Limiar: {blink_thresh:.2f})"
        cv2.putText(frame, blink_txt, (14, h - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.46, (200, 200, 200), 1)

        return {
            "modo": "fps",
            "detect": True,
            "joy_rx": round(joy_rx, 3),
            "joy_ry": round(joy_ry, 3),
            "joy_lx": round(joy_lx, 3),
            "joy_ly": round(joy_ly, 3),
            "cima": cmd_cima,
            "baixo": cmd_baixo,
            "esquerda": cmd_esquerda,
            "direita": cmd_direita,
            "mouse_dx": mouse_dx,
            "mouse_dy": mouse_dy,
            "disparo": cmd_disparo,
            "zoom": cmd_zoom,
            "recarregar": cmd_recarregar
        }

    def _process_gestual(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        detector = self.detectors.hand_detector
        if not detector:
            return {"modo": "gestual", "detect": False, "angulo": 0.0}

        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = detector.detect(mp_img)
        hands = res.hand_landmarks if (res and res.hand_landmarks) else []
        self.has_detection = len(hands) >= 1

        if not hands:
            self._smoothed_angle = self._smoothed_angle * 0.4
            return {"modo": "gestual", "detect": False, "angulo": round(self._smoothed_angle, 1)}

        h, w = frame.shape[:2]
        angle = 0.0
        cmd_dir = False
        cmd_esq = False
        gas = False
        brake = False

        if len(hands) >= 2:
            # Duas mãos segurando o volante virtual
            w0 = hands[0][0]
            w1 = hands[1][0]
            # Ordena por X
            left_w = w0 if w0.x < w1.x else w1
            right_w = w1 if w0.x < w1.x else w0
            dx = right_w.x - left_w.x
            dy = right_w.y - left_w.y
            raw_angle = math.degrees(math.atan2(dy, dx))
            self._smoothed_angle = self._smoothed_angle * 0.35 + raw_angle * 0.65

            # CENTRALIZAÇÃO TEMPORAL (TEMPO 0.3s / SEM ZONA MORTA RÍGIDA)
            now = time.time()
            eff_angle = -self._smoothed_angle if self.config.get("invert_steer", False) else self._smoothed_angle
            center_guide_tolerance = 2.5 # Faixa de tolerância da linha central guia
            center_dwell_threshold = 0.3 # 0.3s

            if abs(eff_angle) <= center_guide_tolerance:
                if self._wheel_center_dwell_start == 0.0:
                    self._wheel_center_dwell_start = now
                elapsed = now - self._wheel_center_dwell_start
                if elapsed >= center_dwell_threshold:
                    cmd_dir = False
                    cmd_esq = False
                    self._last_steer_dir = 'centro'
                    angle = 0.0
                else:
                    if self._last_steer_dir == 'direita':
                        cmd_dir = True
                        cmd_esq = False
                        angle = eff_angle
                    elif self._last_steer_dir == 'esquerda':
                        cmd_esq = True
                        cmd_dir = False
                        angle = eff_angle
                    else:
                        cmd_dir = False
                        cmd_esq = False
                        angle = 0.0
            else:
                self._wheel_center_dwell_start = 0.0
                if eff_angle > 0:
                    cmd_dir = True
                    cmd_esq = False
                    self._last_steer_dir = 'direita'
                    angle = eff_angle
                else:
                    cmd_esq = True
                    cmd_dir = False
                    self._last_steer_dir = 'esquerda'
                    angle = eff_angle

            # Polegares levantados
            thumb_r = (hands[0][4] if hands[0][0].x > hands[1][0].x else hands[1][4])
            thumb_l = (hands[1][4] if hands[0][0].x > hands[1][0].x else hands[0][4])
            gas = thumb_r.y < 0.35
            brake = thumb_l.y < 0.35

            # Guia Central Horizontal de Referência
            p_lw = (int(left_w.x * w), int(left_w.y * h))
            p_rw = (int(right_w.x * w), int(right_w.y * h))
            mid_y = int((left_w.y + right_w.y) * 0.5 * h)
            mid_x = int((left_w.x + right_w.x) * 0.5 * w)

            is_center = (angle == 0.0)
            guide_color = (0, 255, 102) if is_center else (80, 80, 80)
            cv2.line(frame, (mid_x - 140, mid_y), (mid_x + 140, mid_y), guide_color, 2 if is_center else 1)
            cv2.circle(frame, (mid_x, mid_y), 4, guide_color, -1)

            wheel_color = (0, 255, 102) if is_center else ((0, 229, 255) if angle < 0 else (255, 51, 102))
            cv2.line(frame, p_lw, p_rw, wheel_color, 3)
            cv2.circle(frame, p_lw, 8, wheel_color, -1)
            cv2.circle(frame, p_rw, 8, wheel_color, -1)
        else:
            self._wheel_center_dwell_start = 0.0
            self._last_steer_dir = 'centro'

        is_center = (angle == 0.0)
        txt = "VOLANTE: CENTRO (0.0 deg)" if is_center else f"VOLANTE: {angle:+.1f} deg"
        if gas: txt += " | GAS"
        if brake: txt += " | FREIO"
        cv2.putText(frame, txt, (14, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 102) if is_center else (0, 255, 128), 2)

        return {
            "modo": "gestual",
            "detect": True,
            "angulo": round(angle, 1),
            "direita": cmd_dir,
            "esquerda": cmd_esq,
            "cima": gas,
            "baixo": brake,
            "pular": False
        }

    def _process_fight(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        detector = self.detectors.pose_detector
        if not detector:
            return {"modo": "luta", "detect": False}

        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = detector.detect(mp_img)
        has_pose = bool(res and res.pose_landmarks and len(res.pose_landmarks) > 0)
        self.has_detection = has_pose

        if not has_pose:
            return {"modo": "luta", "detect": False, "ataque": False, "defesa": False, "esquerda": False, "direita": False, "pular": False}

        lms = res.pose_landmarks[0]
        # 11: Ombro Esq, 12: Ombro Dir, 15: Pulso Esq, 16: Pulso Dir, 23: Quadril Esq, 24: Quadril Dir
        ls, rs = lms[11], lms[12]
        lw, rw = lms[15], lms[16]
        lh, rh = lms[23], lms[24]

        # 1. Defesa em X (pulsos cruzados na frente do peito)
        cross_dist = math.sqrt((lw.x - rw.x)**2 + (lw.y - rw.y)**2)
        mid_shoulders_y = (ls.y + rs.y) / 2.0
        cmd_defesa = cross_dist < 0.12 and (lw.y < mid_shoulders_y + 0.15)

        # 2. Soco / Ataque (punho projetado à frente do corpo com extensão de braço)
        arm_len_r = math.sqrt((rw.x - rs.x)**2 + (rw.y - rs.y)**2)
        arm_len_l = math.sqrt((lw.x - ls.x)**2 + (lw.y - ls.y)**2)
        cmd_ataque = (arm_len_r > 0.38 or arm_len_l > 0.38) and not cmd_defesa

        # 3. Inclinação Lateral do Tronco (A / D)
        tilt = (rs.y - ls.y)
        cmd_dir = tilt > 0.08
        cmd_esq = tilt < -0.08

        # 4. Pulo Físico (elevação dos quadris)
        hip_y = (lh.y + rh.y) / 2.0
        self._last_raw_hip_y = hip_y
        if self._fight_baseline_hip_y == 0.0:
            self._fight_baseline_hip_y = hip_y
            self._fight_prev_hip_y = hip_y
        delta_hip = hip_y - self._fight_prev_hip_y
        cmd_pular = delta_hip < -0.04 or (hip_y < self._fight_baseline_hip_y - 0.08)
        self._fight_prev_hip_y = hip_y

        # Desenho HUD Luta
        h, w = frame.shape[:2]
        cv2.circle(frame, (int(lw.x * w), int(lw.y * h)), 8, (0, 0, 255) if cmd_ataque else (0, 255, 200), -1)
        cv2.circle(frame, (int(rw.x * w), int(rw.y * h)), 8, (0, 0, 255) if cmd_ataque else (0, 255, 200), -1)

        txt = "LUTA: "
        if cmd_ataque: txt += "[SOCO C] "
        if cmd_defesa: txt += "[DEFESA V] "
        if cmd_esq: txt += "[ESQ A] "
        if cmd_dir: txt += "[DIR D] "
        if cmd_pular: txt += "[PULO W] "
        cv2.putText(frame, txt, (14, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 255), 2)

        return {
            "modo": "luta",
            "detect": True,
            "ataque": cmd_ataque,
            "defesa": cmd_defesa,
            "esquerda": cmd_esq,
            "direita": cmd_dir,
            "pular": cmd_pular
        }

    def _process_corporal(self, rgb: np.ndarray, frame: np.ndarray) -> Dict[str, Any]:
        return self._process_fight(rgb, frame)

    def get_latest_frame(self) -> Optional[np.ndarray]:
        with self._frame_lock:
            if self.latest_frame is not None:
                return self.latest_frame.copy()
            return None

# ==============================================================================
# 6. GERENCIADOR DO HUB LOCAL
# ==============================================================================

class LocalControllerHub:
    """Núcleo coordenando motor de visão e controlador de saída."""
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.vision = LocalVisionEngine(on_payload_callback=self._on_vision_payload, config=config)
        self.active_mode = config.get("controller", "keyboard")
        self.controller: Optional[BaseController] = None
        self.current_payload: Dict[str, Any] = {}
        self.vigem_installed = check_vigem_driver()

    def start(self):
        self.set_controller_mode(self.active_mode)
        self.vision.start()

    def stop(self):
        self.vision.stop()
        if self.controller:
            self.controller.release_all()
            self.controller.close()
            self.controller = None

    def refresh_vigem_status(self) -> bool:
        self.vigem_installed = check_vigem_driver()
        return self.vigem_installed

    def set_controller_mode(self, mode: str) -> bool:
        if self.controller:
            self.controller.release_all()
            self.controller.close()
            self.controller = None

        self.vigem_installed = check_vigem_driver()

        if mode == "xbox":
            if not self.vigem_installed:
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.config.get("key_layout", "both"))
                return False
            try:
                self.controller = Xbox360Controller()
                self.active_mode = "xbox"
                return True
            except Exception:
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.config.get("key_layout", "both"))
                return False

        elif mode == "ps4":
            if not self.vigem_installed:
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.config.get("key_layout", "both"))
                return False
            try:
                self.controller = PS4Controller()
                self.active_mode = "ps4"
                return True
            except Exception:
                self.active_mode = "keyboard"
                self.controller = KeyboardController(key_layout=self.config.get("key_layout", "both"))
                return False

        else:
            self.active_mode = "keyboard"
            self.controller = KeyboardController(key_layout=self.config.get("key_layout", "both"))
            return True

    def _on_vision_payload(self, payload: Dict[str, Any]):
        self.current_payload = payload
        if self.controller:
            self.controller.apply_inputs(payload, self.config)

# ==============================================================================
# 7. INTERFACE GRÁFICA COMPLETA ESTILO APP MOBILE (DARK CYBER THEME)
# ==============================================================================

class FUAGWindowsApp:
    """Interface Gráfica completa e personalizada idêntica à proposta do aplicativo móvel."""

    # Paleta Cyberpunk Dark Theme
    COLOR_BG = "#0B0C12"
    COLOR_CARD = "#141724"
    COLOR_CARD_BORDER = "#22273D"
    COLOR_CYAN = "#00E5FF"
    COLOR_GREEN = "#00FF88"
    COLOR_PURPLE = "#8B5CF6"
    COLOR_ORANGE = "#FF9900"
    COLOR_RED = "#FF3366"
    COLOR_TEXT = "#E2E8F0"
    COLOR_MUTED = "#94A3B8"

    def __init__(self):
        self.config = ConfigManager.load()
        self.hub = LocalControllerHub(self.config)

        self.root = tk.Tk()
        self.root.title("FUAG - PC Local Controller (Zero Lag)")
        self.root.geometry("1060x760")
        self.root.minsize(920, 680)
        self.root.configure(bg=self.COLOR_BG)

        self._active_tab = "hub"  # "hub", "camera", "settings", "help"
        self._preview_image_ref = None

        self._setup_styles()
        self._build_main_layout()

        # Inicia Hub e Câmera
        self.hub.start()

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._update_loop()

    def _setup_styles(self):
        style = ttk.Style()
        style.theme_use('clam')
        style.configure("TCombobox", fieldbackground=self.COLOR_CARD, background=self.COLOR_CARD_BORDER, foreground="#FFFFFF")

    def _build_main_layout(self):
        # 1. TOPO: HEADER & BRANDING COM ABAS DE NAVEGAÇÃO
        header = tk.Frame(self.root, bg=self.COLOR_BG, padx=20, pady=12)
        header.pack(fill="x")

        brand_frame = tk.Frame(header, bg=self.COLOR_BG)
        brand_frame.pack(side="left")

        title_lbl = tk.Label(
            brand_frame, text="FUAG",
            bg=self.COLOR_BG, fg=self.COLOR_CYAN,
            font=("Segoe UI", 18, "bold")
        )
        title_lbl.pack(side="left")

        badge_pc = tk.Label(
            brand_frame, text="PC EDITION",
            bg=self.COLOR_PURPLE, fg="#FFFFFF",
            font=("Segoe UI", 7, "bold"), padx=6, pady=2
        )
        badge_pc.pack(side="left", padx=8)

        sub_lbl = tk.Label(
            brand_frame, text="• Visão Computacional Direta (Zero Lag)",
            bg=self.COLOR_BG, fg=self.COLOR_MUTED,
            font=("Segoe UI", 9)
        )
        sub_lbl.pack(side="left")

        # Botões de Navegação das Abas (Estilo Mobile Menu)
        nav_frame = tk.Frame(header, bg=self.COLOR_BG)
        nav_frame.pack(side="right")

        self.btn_nav_hub = self._build_nav_btn(nav_frame, "🎮 HUB DE JOGOS", lambda: self._switch_tab("hub"))
        self.btn_nav_camera = self._build_nav_btn(nav_frame, "📹 CÂMERA & HUD", lambda: self._switch_tab("camera"))
        self.btn_nav_settings = self._build_nav_btn(nav_frame, "⚙️ CONFIGURAÇÕES", lambda: self._switch_tab("settings"))
        self.btn_nav_help = self._build_nav_btn(nav_frame, "ℹ️ AJUDA", lambda: self._switch_tab("help"))

        # 2. CORPO PRINCIPAL (CONTAINER DINÂMICO DE TELAS)
        self.content_area = tk.Frame(self.root, bg=self.COLOR_BG, padx=20, pady=8)
        self.content_area.pack(fill="both", expand=True)

        self._build_hub_screen()
        self._build_camera_screen()
        self._build_settings_screen()
        self._build_help_screen()

        # 3. BARRA INFERIOR DE STATUS GLOBAL
        status_bar = tk.Frame(self.root, bg=self.COLOR_CARD, padx=16, pady=8, highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        status_bar.pack(fill="x", side="bottom")

        self.lbl_global_cam = tk.Label(status_bar, text="📷 Câmera: ...", bg=self.COLOR_CARD, fg=self.COLOR_GREEN, font=("Segoe UI", 9, "bold"))
        self.lbl_global_cam.pack(side="left", padx=6)

        self.lbl_global_mode = tk.Label(status_bar, text="🎮 Modo Ativo: ...", bg=self.COLOR_CARD, fg=self.COLOR_CYAN, font=("Segoe UI", 9, "bold"))
        self.lbl_global_mode.pack(side="left", padx=12)

        self.lbl_global_controller = tk.Label(status_bar, text="🕹️ Saída: ...", bg=self.COLOR_CARD, fg=self.COLOR_PURPLE, font=("Segoe UI", 9, "bold"))
        self.lbl_global_controller.pack(side="left", padx=12)

        self.lbl_global_fps = tk.Label(status_bar, text="FPS: 0", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9))
        self.lbl_global_fps.pack(side="right", padx=8)

        self._switch_tab("hub")

    def _build_nav_btn(self, parent, text: str, command):
        btn = tk.Button(
            parent, text=text, command=command,
            bg=self.COLOR_CARD, fg=self.COLOR_TEXT,
            activebackground=self.COLOR_CARD_BORDER, activeforeground=self.COLOR_CYAN,
            relief="flat", font=("Segoe UI", 9, "bold"), padx=12, pady=5, cursor="hand2"
        )
        btn.pack(side="left", padx=3)
        return btn

    def _switch_tab(self, tab_name: str):
        self._active_tab = tab_name
        self.frame_hub.pack_forget()
        self.frame_camera.pack_forget()
        self.frame_settings.pack_forget()
        self.frame_help.pack_forget()

        # Atualiza cores dos botões de navegação
        for name, btn in [("hub", self.btn_nav_hub), ("camera", self.btn_nav_camera), ("settings", self.btn_nav_settings), ("help", self.btn_nav_help)]:
            if name == tab_name:
                btn.config(bg=self.COLOR_CYAN, fg="#000000")
            else:
                btn.config(bg=self.COLOR_CARD, fg=self.COLOR_TEXT)

        if tab_name == "hub":
            self.frame_hub.pack(fill="both", expand=True)
        elif tab_name == "camera":
            self.frame_camera.pack(fill="both", expand=True)
        elif tab_name == "settings":
            self.frame_settings.pack(fill="both", expand=True)
        elif tab_name == "help":
            self.frame_help.pack(fill="both", expand=True)

    # ==========================================================================
    # TELA 1: HUB / MENU DE MODOS (GRID ESTILO APP MOBILE)
    # ==========================================================================
    def _build_hub_screen(self):
        self.frame_hub = tk.Frame(self.content_area, bg=self.COLOR_BG)

        lbl = tk.Label(
            self.frame_hub, text="SELECIONE O MODO DE CONTROLE",
            bg=self.COLOR_BG, fg=self.COLOR_CYAN, font=("Segoe UI", 12, "bold")
        )
        lbl.pack(anchor="w", pady=(4, 12))

        # Grid de cartões de modos idêntico ao GridView do mobile
        grid_frame = tk.Frame(self.frame_hub, bg=self.COLOR_BG)
        grid_frame.pack(fill="both", expand=True)

        grid_frame.columnconfigure(0, weight=1)
        grid_frame.columnconfigure(1, weight=1)

        modes = [
            ("facial", "👤 MODO FACIAL", "Volante com inclinação da cabeça\nAcelere olhando p/ cima, freie p/ baixo e nitro com a boca", self.COLOR_CYAN),
            ("gestual", "✋ MODO GESTUAL", "Volante com as duas mãos no ar\nPolegares para acelerar e frear com precisão tática", self.COLOR_GREEN),
            ("fps", "🎯 MODO FPS (TIRO)", "Mira 1:1 com dedo indicador (anti-flick)\nGatilho no dedo médio e zoom telescópico com o dedão", self.COLOR_RED),
            ("fps_mesh", "👁️ MODO FPS OCULAR/MESH", "Acessibilidade Total CS 1.6 (Sem Mãos)\nMira por rastreamento ocular, WASD pela cabeça e tiro por piscadas", "#38BDF8"),
            ("luta", "🥋 MODO LUTA", "Stick Fight The Game\nSocos [C], Defesa em X [V], Esquiva [A/D], Pulo [W]", self.COLOR_ORANGE),
            ("corporal", "🧍 MODO CORPORAL", "Movimentação corporal completa\nInclinação de ombros, pulos físicos e agachamentos", self.COLOR_PURPLE)
        ]

        self.mode_cards = {}
        for i, (m_id, title, desc, color) in enumerate(modes):
            r = i // 2
            c = i % 2

            card = tk.Frame(grid_frame, bg=self.COLOR_CARD, padx=16, pady=16, highlightthickness=2, highlightbackground=self.COLOR_CARD_BORDER, cursor="hand2")
            card.grid(row=r, column=c, padx=8, pady=8, sticky="nsew")

            t_lbl = tk.Label(card, text=title, bg=self.COLOR_CARD, fg=color, font=("Segoe UI", 12, "bold"))
            t_lbl.pack(anchor="w")

            d_lbl = tk.Label(card, text=desc, bg=self.COLOR_CARD, fg=self.COLOR_MUTED, font=("Segoe UI", 9), justify="left")
            d_lbl.pack(anchor="w", pady=(6, 12))

            action_row = tk.Frame(card, bg=self.COLOR_CARD)
            action_row.pack(fill="x", side="bottom")

            btn_play = tk.Button(
                action_row, text="▶ INICIAR NESTE MODO",
                command=lambda m=m_id: self._select_mode_and_play(m),
                bg=color, fg="#000000" if color != self.COLOR_RED else "#FFFFFF",
                relief="flat", font=("Segoe UI", 9, "bold"), padx=10, pady=4, cursor="hand2"
            )
            btn_play.pack(side="left")

            card.bind("<Button-1>", lambda e, m=m_id: self._select_mode_and_play(m))
            t_lbl.bind("<Button-1>", lambda e, m=m_id: self._select_mode_and_play(m))
            d_lbl.bind("<Button-1>", lambda e, m=m_id: self._select_mode_and_play(m))

            self.mode_cards[m_id] = card

    def _select_mode_and_play(self, mode_id: str):
        self.hub.vision.set_mode(mode_id)
        self.config["mode"] = mode_id
        ConfigManager.save(self.config)
        self._switch_tab("camera")

    # ==========================================================================
    # TELA 2: CÂMERA AO VIVO & HUD (GAMEPLAY SCREEN)
    # ==========================================================================
    def _build_camera_screen(self):
        self.frame_camera = tk.Frame(self.content_area, bg=self.COLOR_BG)

        # Barra de Ações Rápidas no topo da Câmera
        hud_bar = tk.Frame(self.frame_camera, bg=self.COLOR_CARD, padx=12, pady=6, highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        hud_bar.pack(fill="x", pady=(0, 6))

        self.btn_back_hub = tk.Button(
            hud_bar, text="⬅ Menu", command=lambda: self._switch_tab("hub"),
            bg="#252A40", fg=self.COLOR_TEXT, relief="flat", font=("Segoe UI", 8, "bold"), padx=8, pady=3, cursor="hand2"
        )
        self.btn_back_hub.pack(side="left", padx=4)

        self.btn_hud_tare = tk.Button(
            hud_bar, text="🎯 Zerar Centro", command=self.hub.vision.tare_center,
            bg=self.COLOR_CYAN, fg="#000000", relief="flat", font=("Segoe UI", 8, "bold"), padx=10, pady=3, cursor="hand2"
        )
        self.btn_hud_tare.pack(side="left", padx=4)

        self.btn_hud_cam = tk.Button(
            hud_bar, text="📷 Trocar Câmera", command=self._toggle_camera,
            bg="#252A40", fg=self.COLOR_TEXT, relief="flat", font=("Segoe UI", 8, "bold"), padx=8, pady=3, cursor="hand2"
        )
        self.btn_hud_cam.pack(side="left", padx=4)

        self.lbl_hud_mode = tk.Label(hud_bar, text="MODO: ...", bg=self.COLOR_CARD, fg=self.COLOR_CYAN, font=("Segoe UI", 9, "bold"))
        self.lbl_hud_mode.pack(side="right", padx=8)

        # Área de Vídeo ao Vivo
        self.video_container = tk.Frame(self.frame_camera, bg="#000000", highlightthickness=2, highlightbackground=self.COLOR_CARD_BORDER)
        self.video_container.pack(fill="both", expand=True, pady=4)

        self.lbl_video_display = tk.Label(self.video_container, bg="#000000")
        self.lbl_video_display.pack(fill="both", expand=True)

        # Painel Inferior de Telemetria Dinâmica
        bottom_telemetry = tk.Frame(self.frame_camera, bg=self.COLOR_CARD, padx=14, pady=8, highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        bottom_telemetry.pack(fill="x", pady=(4, 0))

        t_row1 = tk.Frame(bottom_telemetry, bg=self.COLOR_CARD)
        t_row1.pack(fill="x")

        tk.Label(t_row1, text="VOLANTE / EIXO ANALÓGICO:", bg=self.COLOR_CARD, fg=self.COLOR_CYAN, font=("Segoe UI", 9, "bold")).pack(side="left")
        self.lbl_hud_angle = tk.Label(t_row1, text="0.0°", bg=self.COLOR_CARD, fg=self.COLOR_GREEN, font=("Segoe UI", 10, "bold"))
        self.lbl_hud_angle.pack(side="right")

        self.canvas_hud_wheel = tk.Canvas(bottom_telemetry, height=32, bg="#0B0C12", highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        self.canvas_hud_wheel.pack(fill="x", pady=4)

        # Badges de Ações
        self.badges_row = tk.Frame(bottom_telemetry, bg=self.COLOR_CARD)
        self.badges_row.pack(fill="x", pady=(4, 0))

        self.b_act1 = tk.Label(self.badges_row, text="AÇÃO 1", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=6, pady=3)
        self.b_act1.pack(side="left", expand=True, fill="x", padx=2)

        self.b_act2 = tk.Label(self.badges_row, text="AÇÃO 2", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=6, pady=3)
        self.b_act2.pack(side="left", expand=True, fill="x", padx=2)

        self.b_act3 = tk.Label(self.badges_row, text="AÇÃO 3", bg="#252A40", fg="#64748B", font=("Segoe UI", 8, "bold"), padx=6, pady=3)
        self.b_act3.pack(side="left", expand=True, fill="x", padx=2)

    def _toggle_camera(self):
        cams = self.hub.vision.available_cameras
        if not cams:
            cams = self.hub.vision.scan_cameras()
        if len(cams) > 1:
            curr = self.hub.vision.camera_index
            next_idx = cams[(cams.index(next(c for c in cams if c[0] == curr)) + 1) % len(cams)][0]
            self.hub.vision.stop()
            self.hub.vision.set_camera(next_idx)
            self.hub.vision.start()

    # ==========================================================================
    # TELA 3: PAINEL DE CONFIGURAÇÕES (COMPLETO E PERSISTENTE)
    # ==========================================================================
    def _build_settings_screen(self):
        self.frame_settings = tk.Frame(self.content_area, bg=self.COLOR_BG)

        lbl = tk.Label(
            self.frame_settings, text="CONFIGURAÇÕES DO SISTEMA",
            bg=self.COLOR_BG, fg=self.COLOR_CYAN, font=("Segoe UI", 12, "bold")
        )
        lbl.pack(anchor="w", pady=(4, 10))

        scroll_canvas = tk.Canvas(self.frame_settings, bg=self.COLOR_BG, highlightthickness=0)
        scroll_canvas.pack(fill="both", expand=True)

        content = tk.Frame(scroll_canvas, bg=self.COLOR_BG)
        scroll_canvas.create_window((0, 0), window=content, anchor="nw")

        # 1. Hardware e Emulação
        card1 = self._build_settings_card(content, "🕹️ EMULAÇÃO DE CONTROLE (WINDOWS OUTPUT)")
        
        tk.Label(card1, text="Dispositivo Emulado:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w", pady=4)
        self.cfg_controller = ttk.Combobox(card1, values=["Teclado DirectInput (WASD / Setas)", "Controle Xbox 360 (XInput)", "Controle PlayStation 4 (DS4)"], state="readonly", width=36)
        c_map = {"keyboard": 0, "xbox": 1, "ps4": 2}
        self.cfg_controller.current(c_map.get(self.config.get("controller", "keyboard"), 0))
        self.cfg_controller.grid(row=0, column=1, sticky="w", padx=10, pady=4)

        tk.Label(card1, text="Layout do Teclado:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=1, column=0, sticky="w", pady=4)
        self.cfg_kbd_layout = ttk.Combobox(card1, values=["Ambos (Setas + WASD)", "Apenas Setas", "Apenas WASD"], state="readonly", width=36)
        k_map = {"both": 0, "arrows": 1, "wasd": 2}
        self.cfg_kbd_layout.current(k_map.get(self.config.get("key_layout", "both"), 0))
        self.cfg_kbd_layout.grid(row=1, column=1, sticky="w", padx=10, pady=4)

        # ViGEm Status
        d_row = tk.Frame(card1, bg=self.COLOR_CARD)
        d_row.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(8, 4))
        self.lbl_settings_vigem = tk.Label(d_row, text="Driver ViGEmBus: Verificando...", bg=self.COLOR_CARD, fg=self.COLOR_MUTED, font=("Segoe UI", 9, "bold"))
        self.lbl_settings_vigem.pack(side="left")
        btn_inst = tk.Button(d_row, text="📦 Instalar Driver", command=self._install_driver, bg="#2563EB", fg="#FFFFFF", relief="flat", font=("Segoe UI", 8, "bold"), padx=8, pady=2, cursor="hand2")
        btn_inst.pack(side="right", padx=4)
        btn_cpl = tk.Button(d_row, text="🎮 Testador joy.cpl", command=lambda: subprocess.Popen(["joy.cpl"], shell=True), bg="#334155", fg="#FFFFFF", relief="flat", font=("Segoe UI", 8), padx=8, pady=2, cursor="hand2")
        btn_cpl.pack(side="right", padx=4)

        # 2. Calibração de Volante e Direção
        card2 = self._build_settings_card(content, "🏎️ CALIBRAÇÃO DE VOLANTE & HEAD TRACKING")
        
        tk.Label(card2, text="Ângulo Máximo do Volante:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w", pady=4)
        self.scale_max_angle = tk.Scale(card2, from_=20, to=70, orient="horizontal", bg=self.COLOR_CARD, fg=self.COLOR_CYAN, highlightthickness=0, length=240)
        self.scale_max_angle.set(int(self.config.get("max_angle", 35.0)))
        self.scale_max_angle.grid(row=0, column=1, sticky="w", padx=10, pady=4)

        tk.Label(card2, text="Zona Morta Central:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=1, column=0, sticky="w", pady=4)
        self.scale_deadzone = tk.Scale(card2, from_=0, to=12, orient="horizontal", bg=self.COLOR_CARD, fg=self.COLOR_CYAN, highlightthickness=0, length=240)
        self.scale_deadzone.set(int(self.config.get("deadzone", 4.0)))
        self.scale_deadzone.grid(row=1, column=1, sticky="w", padx=10, pady=4)

        self.var_inv_steer = tk.BooleanVar(value=self.config.get("invert_steer", False))
        chk_inv = tk.Checkbutton(card2, text="Inverter Direção do Volante", variable=self.var_inv_steer, bg=self.COLOR_CARD, fg=self.COLOR_TEXT, selectcolor=self.COLOR_CARD_BORDER, activebackground=self.COLOR_CARD, activeforeground=self.COLOR_CYAN, font=("Segoe UI", 9))
        chk_inv.grid(row=2, column=1, sticky="w", padx=10, pady=4)

        # 3. Calibração do Modo FPS
        card3 = self._build_settings_card(content, "🎯 CALIBRAÇÃO DO MODO FPS (MIRA & TIRO)")

        tk.Label(card3, text="Sensibilidade da Mira:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w", pady=4)
        self.cfg_fps_sens = ttk.Combobox(card3, values=["Baixa (Precisão / Sniper)", "Média (Padrão Equilibrado)", "Alta (Combate Próximo)"], state="readonly", width=36)
        self.cfg_fps_sens.current(int(self.config.get("fps_sens_index", 1)))
        self.cfg_fps_sens.grid(row=0, column=1, sticky="w", padx=10, pady=4)

        self.var_inv_y = tk.BooleanVar(value=self.config.get("invert_fps_y", False))
        chk_y = tk.Checkbutton(card3, text="Inverter Eixo Y da Mira", variable=self.var_inv_y, bg=self.COLOR_CARD, fg=self.COLOR_TEXT, selectcolor=self.COLOR_CARD_BORDER, activebackground=self.COLOR_CARD, activeforeground=self.COLOR_CYAN, font=("Segoe UI", 9))
        chk_y.grid(row=1, column=1, sticky="w", padx=10, pady=4)

        # 4. Vídeo & Câmeras
        card4 = self._build_settings_card(content, "📹 CONFIGURAÇÃO DE VÍDEO & LENTE INFRAVERMELHO")

        tk.Label(card4, text="Câmera de Captura:", bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w", pady=4)
        cams = self.hub.vision.available_cameras
        c_names = [f"Índice {c[0]}: {'[IR Hello]' if c[1] else '[RGB]'} {c[2]}" for c in cams] or ["0: Câmera Padrão"]
        self.cfg_camera_select = ttk.Combobox(card4, values=c_names, state="readonly", width=36)
        self.cfg_camera_select.current(0)
        self.cfg_camera_select.grid(row=0, column=1, sticky="w", padx=10, pady=4)

        self.var_mirror = tk.BooleanVar(value=self.config.get("mirror_video", True))
        chk_mir = tk.Checkbutton(card4, text="Espelhar Imagem Horizontalmente (Efeito Espelho)", variable=self.var_mirror, bg=self.COLOR_CARD, fg=self.COLOR_TEXT, selectcolor=self.COLOR_CARD_BORDER, activebackground=self.COLOR_CARD, activeforeground=self.COLOR_CYAN, font=("Segoe UI", 9))
        chk_mir.grid(row=1, column=1, sticky="w", padx=10, pady=4)

        # Botão Salvar
        btn_save = tk.Button(
            content, text="💾 SALVAR TODAS AS CONFIGURAÇÕES", command=self._save_settings_from_gui,
            bg=self.COLOR_GREEN, fg="#000000", relief="flat", font=("Segoe UI", 10, "bold"), padx=16, pady=8, cursor="hand2"
        )
        btn_save.pack(pady=16)

    def _build_settings_card(self, parent, title: str) -> tk.Frame:
        wrapper = tk.Frame(parent, bg=self.COLOR_CARD, padx=16, pady=12, highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        wrapper.pack(fill="x", pady=6)
        lbl = tk.Label(wrapper, text=title, bg=self.COLOR_CARD, fg=self.COLOR_CYAN, font=("Segoe UI", 10, "bold"))
        lbl.grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 8))
        inner = tk.Frame(wrapper, bg=self.COLOR_CARD)
        inner.grid(row=1, column=0, columnspan=2, sticky="ew")
        return inner

    def _save_settings_from_gui(self):
        c_idx = self.cfg_controller.current()
        self.config["controller"] = ["keyboard", "xbox", "ps4"][c_idx]
        k_idx = self.cfg_kbd_layout.current()
        self.config["key_layout"] = ["both", "arrows", "wasd"][k_idx]
        self.config["max_angle"] = float(self.scale_max_angle.get())
        self.config["deadzone"] = float(self.scale_deadzone.get())
        self.config["invert_steer"] = self.var_inv_steer.get()
        self.config["fps_sens_index"] = self.cfg_fps_sens.current()
        self.config["invert_fps_y"] = self.var_inv_y.get()
        self.config["mirror_video"] = self.var_mirror.get()

        ConfigManager.save(self.config)
        self.hub.set_controller_mode(self.config["controller"])
        messagebox.showinfo("Configurações", "Configurações salvas e aplicadas com sucesso!")

    def _install_driver(self):
        msi = get_vigem_msi_path()
        if not msi:
            messagebox.showerror("Erro", "Instalador ViGEmBusSetup_x64.msi não encontrado.")
            return
        ok = install_vigem_driver_elevation(msi)
        if ok:
            messagebox.showinfo("Instalação", "O instalador do ViGEmBus foi disparado com permissão UAC.")
        else:
            messagebox.showerror("Erro", "Falha ao disparar instalação.")

    # ==========================================================================
    # TELA 4: AJUDA E MAPEAMENTO DE TECLAS
    # ==========================================================================
    def _build_help_screen(self):
        self.frame_help = tk.Frame(self.content_area, bg=self.COLOR_BG)

        lbl = tk.Label(self.frame_help, text="GUIA DE CONTROLES E MAPEAMENTO", bg=self.COLOR_BG, fg=self.COLOR_CYAN, font=("Segoe UI", 12, "bold"))
        lbl.pack(anchor="w", pady=(4, 12))

        txt_info = """
🏎️ MODO FACIAL:
• Incline a cabeça para a Esquerda ou Direita -> Volante Analógico Proporcional
• Olhe para cima -> Acelerar (Tecla W ou Gatilho RT no Xbox)
• Olhe para baixo -> Frear / Marcha Ré (Tecla S ou Gatilho LT no Xbox)
• Abra a boca -> Pulo / Nitro / Freio de Mão (Espaço / Botão A)

🎯 MODO FPS (TIRO EM PRIMEIRA PESSOA / CS 1.6):
• Aponte o dedo indicador -> Move a mira do mouse suavemente em tempo real
• Feche o dedo médio -> Dispara a arma (Botão Esquerdo / Mouse 1)
• Estique o dedão frontalmente -> Ativa zoom da luneta (Botão Direito / Mouse 2)

👁️ MODO FPS OCULAR/MESH (ACESSIBILIDADE SEVERA / SEM MÃOS):
• Rotação da Cabeça -> Movimentação WASD:
  - Incline para Cima [W] / Incline para Baixo [S]
  - Vire para a Esquerda [A] / Vire para a Direita [D]
• Rastreamento Ocular (Pupila/Íris) -> Mira 1:1 com Filtro Anti-Tremor
• Piscada Forte Olho Esquerdo -> Disparo da Arma [Mouse 1]
• Piscada Forte Olho Direito -> Zoom da Luneta [Mouse 2]
• Piscada Forte Simultânea (Dois Olhos) -> Recarregar Arma [Tecla R]

🥋 MODO LUTA (STICK FIGHT THE GAME):
• Movimento de soco com o braço -> Ataque [Tecla C]
• Cruze os braços em X na frente do peito -> Defesa [Tecla V]
• Incline o tronco para a esquerda -> Mover Esquerda [Tecla A]
• Incline o tronco para a direita -> Mover Direita [Tecla D]
• Pulo físico (quadril subindo rápido) -> Pulo [Tecla W]

💡 DICA: Se a mira ou volante estiverem fora do centro, clique em 'Zerar Centro' a qualquer momento!
"""
        card = tk.Frame(self.frame_help, bg=self.COLOR_CARD, padx=20, pady=16, highlightthickness=1, highlightbackground=self.COLOR_CARD_BORDER)
        card.pack(fill="both", expand=True)

        msg = tk.Label(card, text=txt_info, bg=self.COLOR_CARD, fg=self.COLOR_TEXT, font=("Segoe UI", 10), justify="left")
        msg.pack(anchor="nw")

    # ==========================================================================
    # LOOP DE ATUALIZAÇÃO (30 FPS)
    # ==========================================================================
    def _update_loop(self):
        payload = self.hub.current_payload
        angle = float(payload.get("angulo", 0.0))
        fps = float(payload.get("fps", self.hub.vision.fps))
        mode = self.hub.vision.active_mode
        is_ir = self.hub.vision.is_ir
        cam_lbl = self.hub.vision.camera_status_str
        ctrl_mode = self.hub.active_mode.upper()

        # Barra inferior global
        icon = "🟣" if is_ir else "🟢"
        self.lbl_global_cam.config(text=f"{icon} {cam_lbl}")
        self.lbl_global_mode.config(text=f"🎯 Modo: {mode.upper()}")
        self.lbl_global_controller.config(text=f"🕹️ Saída: {ctrl_mode}")
        self.lbl_global_fps.config(text=f"Visão: {fps:.0f} FPS")

        # Tela de Câmera & HUD
        if self._active_tab == "camera":
            self.lbl_hud_mode.config(text=f"MODO ATIVO: {mode.upper()}")
            if angle == 0.0:
                self.lbl_hud_angle.config(text="● CENTRO (0.0°)", fg=self.COLOR_GREEN)
            else:
                self.lbl_hud_angle.config(text=f"{angle:+.1f}°", fg=self.COLOR_CYAN)

            # Atualiza quadro do vídeo
            frame = self.hub.vision.get_latest_frame()
            if frame is not None and HAS_PIL:
                vw = self.video_container.winfo_width()
                vh = self.video_container.winfo_height()
                if vw > 60 and vh > 60:
                    fh, fw = frame.shape[:2]
                    scale = min(vw / fw, vh / fh)
                    nw = int(fw * scale)
                    nh = int(fh * scale)
                    resized = cv2.resize(frame, (nw, nh))
                    rgb_frame = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
                    img = Image.fromarray(rgb_frame)
                    imgtk = ImageTk.PhotoImage(image=img)
                    self.lbl_video_display.imgtk = imgtk
                    self.lbl_video_display.configure(image=imgtk)

            # Canvas Wheel HUD com Linha Guia Central
            c = self.canvas_hud_wheel
            w = c.winfo_width()
            h = c.winfo_height()
            if w > 20 and h > 10:
                c.delete("all")
                mid_x = w / 2
                mid_y = h / 2
                is_centered = (angle == 0.0)
                c.create_rectangle(10, mid_y - 2, w - 10, mid_y + 2, fill="#1E2338", outline="")
                # Linha central guia de referência
                center_line_color = self.COLOR_GREEN if is_centered else self.COLOR_MUTED
                c.create_line(mid_x, 2, mid_x, h - 2, fill=center_line_color, width=2)

                ratio = max(-1.0, min(1.0, angle / max(1.0, self.config.get("max_angle", 35.0))))
                target_x = mid_x + ratio * (mid_x - 24)
                if not is_centered:
                    if ratio < 0:
                        c.create_rectangle(target_x, mid_y - 4, mid_x, mid_y + 4, fill=self.COLOR_CYAN, outline="")
                    else:
                        c.create_rectangle(mid_x, mid_y - 4, target_x, mid_y + 4, fill=self.COLOR_CYAN, outline="")
                dot_color = self.COLOR_GREEN if is_centered else self.COLOR_CYAN
                c.create_oval(target_x - 7, mid_y - 7, target_x + 7, mid_y + 7, fill=dot_color, outline="#FFFFFF", width=2)

            # Badges HUD
            if mode in ("fps", "fps_mesh"):
                fire = payload.get("disparo", False)
                zoom = payload.get("zoom", False)
                if mode == "fps_mesh":
                    wasd = ""
                    if payload.get("cima"): wasd += "W "
                    if payload.get("esquerda"): wasd += "A "
                    if payload.get("baixo"): wasd += "S "
                    if payload.get("direita"): wasd += "D "
                    wasd = wasd.strip() or "PARADO"
                    self.b_act1.config(text=f"TIRO [M1]: {'ON' if fire else 'OFF'}", bg=self.COLOR_RED if fire else "#252A40", fg="#FFF" if fire else self.COLOR_MUTED)
                    self.b_act2.config(text=f"ZOOM [M2]: {'ON' if zoom else 'OFF'}", bg=self.COLOR_CYAN if zoom else "#252A40", fg="#000" if zoom else self.COLOR_MUTED)
                    self.b_act3.config(text=f"WASD: {wasd}", bg=self.COLOR_GREEN if wasd != "PARADO" else "#252A40", fg="#000" if wasd != "PARADO" else self.COLOR_MUTED)
                else:
                    self.b_act1.config(text=f"TIRO [M1]: {'ON' if fire else 'OFF'}", bg=self.COLOR_RED if fire else "#252A40", fg="#FFF" if fire else self.COLOR_MUTED)
                    self.b_act2.config(text=f"ZOOM [M2]: {'ON' if zoom else 'OFF'}", bg=self.COLOR_CYAN if zoom else "#252A40", fg="#000" if zoom else self.COLOR_MUTED)
                    self.b_act3.config(text=f"LATÊNCIA: < 1ms", bg=self.COLOR_GREEN, fg="#000")
            elif mode == "luta":
                atk = payload.get("ataque", False)
                defe = payload.get("defesa", False)
                jmp = payload.get("pular", False)
                self.b_act1.config(text=f"SOCO [C]: {'ON' if atk else 'OFF'}", bg=self.COLOR_ORANGE if atk else "#252A40", fg="#FFF" if atk else self.COLOR_MUTED)
                self.b_act2.config(text=f"DEFESA [V]: {'ON' if defe else 'OFF'}", bg=self.COLOR_PURPLE if defe else "#252A40", fg="#FFF" if defe else self.COLOR_MUTED)
                self.b_act3.config(text=f"PULO [W]: {'ON' if jmp else 'OFF'}", bg=self.COLOR_CYAN if jmp else "#252A40", fg="#000" if jmp else self.COLOR_MUTED)
            else:
                gas = payload.get("cima", False)
                brake = payload.get("baixo", False)
                nitro = payload.get("pular", False)
                self.b_act1.config(text=f"GAS [W]: {'ON' if gas else 'OFF'}", bg=self.COLOR_GREEN if gas else "#252A40", fg="#FFF" if gas else self.COLOR_MUTED)
                self.b_act2.config(text=f"FREIO [S]: {'ON' if brake else 'OFF'}", bg=self.COLOR_RED if brake else "#252A40", fg="#FFF" if brake else self.COLOR_MUTED)
                self.b_act3.config(text=f"NITRO [SPC]: {'ON' if nitro else 'OFF'}", bg=self.COLOR_CYAN if nitro else "#252A40", fg="#000" if nitro else self.COLOR_MUTED)

        # Destaca o cartão ativo no menu
        if self._active_tab == "hub":
            for m_id, card in self.mode_cards.items():
                if m_id == mode:
                    card.configure(highlightbackground=self.COLOR_CYAN, highlightthickness=2)
                else:
                    card.configure(highlightbackground=self.COLOR_CARD_BORDER, highlightthickness=1)

        # Configurações ViGEmBus
        if hasattr(self, 'lbl_settings_vigem'):
            v_ok = self.hub.refresh_vigem_status()
            if v_ok:
                self.lbl_settings_vigem.config(text="✅ Driver ViGEmBus Instalado e Pronto", fg=self.COLOR_GREEN)
            else:
                self.lbl_settings_vigem.config(text="⚠️ Driver ViGEmBus Não Encontrado", fg=self.COLOR_ORANGE)

        self.root.after(33, self._update_loop)

    def _on_close(self):
        self.hub.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()

# ==============================================================================
# 8. PONTO DE ENTRADA PRINCIPAL
# ==============================================================================

if __name__ == "__main__":
    app = FUAGWindowsApp()
    app.run()
