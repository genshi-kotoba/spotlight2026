"""Create an isolated macOS app from installed Godot 4.7.2 templates.

No download, signing, publishing or launch. The repository remains a normal
Godot project; this bundle is only a native acceptance/demo convenience.
"""
import argparse
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--godot', type=Path, required=True)
parser.add_argument('--template', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=True)
stage = args.output / 'runtime-source'
stage.mkdir(exist_ok=True)
files = ['systems/map/hex_coord.gd', 'core/signals/map_events.gd',
         'tools/map_flat_2d/pack_native.gd']
for folder in ['systems/map/flat_2d', 'ui/world_map/flat_2d', 'data/config/flat_2d']:
    files.extend(str(p.relative_to(root)) for p in (root / folder).glob('*')
                 if p.suffix in {'.gd', '.tscn', '.json'})
for name in files:
    dest = stage / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, dest)
(stage / 'project.godot').write_text('''config_version=5
[application]
config/name="Spotlight Flat 2D Demo"
run/main_scene="res://ui/world_map/flat_2d/map_demo.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
[autoload]
MapEvents="*res://core/signals/map_events.gd"
[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/size/window_width_override=1280
window/size/window_height_override=800
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
''')
subprocess.run([str(args.godot), '--headless', '--editor', '--path', str(stage),
                '--import', '--log-file', str(args.output / 'import.log')], check=True)
app = args.output / 'Map Flat 2D Demo.app'
resources = app / 'Contents/Resources'
executables = app / 'Contents/MacOS'
resources.mkdir(parents=True, exist_ok=True)
executables.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.template) as template:
    runtime = executables / 'MapFlatDemo.pending'
    runtime.write_bytes(template.read('macos_template.app/Contents/MacOS/godot_macos_debug.universal'))
    runtime.chmod(0o755)
    runtime.replace(executables / 'MapFlatDemo')
    for name in ['PrivacyInfo.xcprivacy', 'icon.icns']:
        (resources / name).write_bytes(template.read('macos_template.app/Contents/Resources/' + name))
    (app / 'Contents/PkgInfo').write_bytes(template.read('macos_template.app/Contents/PkgInfo'))
info = {'CFBundleIdentifier': 'local.spotlight.map-flat-demo',
        'CFBundleDisplayName': 'Map Flat 2D Demo', 'CFBundleName': 'Map Flat 2D Demo',
        'CFBundleExecutable': 'MapFlatDemo', 'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'icon.icns', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '0.1', 'NSHighResolutionCapable': True}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run([str(args.godot), '--headless', '--path', str(stage), '--script',
                'res://tools/map_flat_2d/pack_native.gd', '--log-file',
                str(args.output / 'build.log'), '--', str(resources / 'MapFlatDemo.pck')], check=True)
print(app)
