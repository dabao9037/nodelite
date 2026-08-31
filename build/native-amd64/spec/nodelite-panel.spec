# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['/tmp/nodelite-native-impl/native/panel_entry.py'],
    pathex=['/tmp/nodelite-native-impl'],
    binaries=[],
    datas=[('/tmp/nodelite-native-impl/app/static', 'app/static')],
    hiddenimports=['app.main'],
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
    [],
    exclude_binaries=True,
    name='nodelite-panel',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='nodelite-panel',
)
