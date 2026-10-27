# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_all

datas = [
    ('face_landmarker.task', '.'),
    ('hand_landmarker.task', '.'),
    ('pose_landmarker_lite.task', '.'),
    ('tools', 'tools'),
]
binaries = []
hiddenimports = [
    'PIL.Image',
    'PIL.ImageTk',
    'PIL.ImageDraw',
    'vgamepad',
    'pydirectinput',
]

mp_datas, mp_binaries, mp_hidden = collect_all('mediapipe')
datas += mp_datas
binaries += mp_binaries
hiddenimports += mp_hidden

cv2_datas, cv2_binaries, cv2_hidden = collect_all('cv2')
datas += cv2_datas
binaries += cv2_binaries
hiddenimports += cv2_hidden

a = Analysis(
    ['pc_local_controller.py'],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='PCLocalController',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

