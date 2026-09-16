#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNTIME="${ZIPRIPPER_RUNTIME:-$ROOT/.local/runtime}"
if [ ! -x "$RUNTIME/bin/john" ]; then
  echo 'Build the runtime first: scripts/build-runtime.sh' >&2
  exit 1
fi
swift build -c release -Xswiftc -DZIPRIPPER_PACKAGED -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/source/ZipRipper"
BIN="$(swift build -c release --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$ROOT/dist/package.XXXXXXXX")"
APP="$STAGE/ZipRipper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ZipRipper" "$APP/Contents/MacOS/ZipRipper"
# Remove linker debug-map object paths from the public executable.
xcrun strip -S "$APP/Contents/MacOS/ZipRipper"
cp -R "$BIN/ZipRipper_ZipRipperCore.bundle" "$BIN/ZipRipper_ZipRipperApp.bundle" "$APP/Contents/Resources/"
cp -R "$RUNTIME" "$APP/Contents/Resources/runtime"
cp assets/AppIcon.icns "$APP/Contents/Resources/MascotIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ZipRipper</string>
<key>CFBundleIdentifier</key><string>com.zipripper.macos</string>
<key>CFBundleName</key><string>ZipRipper</string>
<key>CFBundleDisplayName</key><string>ZipRipper</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.5.3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>MascotIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Protected archives and documents</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>CFBundleTypeExtensions</key><array><string>zip</string><string>rar</string><string>7z</string><string>pdf</string></array>
</dict></array>
</dict></plist>
PLIST
# Explicitly sign nested native code, then seal the app. Ad-hoc is local only.
/usr/bin/python3 - "$APP" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1])
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    with path.open('rb') as f: magic = f.read(4)
    if magic in [bytes.fromhex(x) for x in ('cffaedfe','cefaedfe','cafebabe','bebafeca')]:
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(path)], check=True)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ -e dist/ZipRipper.app ]; then mv dist/ZipRipper.app "$STAGE/previous-ZipRipper.app"; fi
mv "$APP" dist/ZipRipper.app
echo "$ROOT/dist/ZipRipper.app"
