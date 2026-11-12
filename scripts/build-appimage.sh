#!/bin/bash
# Build ReOculus-<version>-x86_64.AppImage from the release builds.
# Run on the main PC from the project root (canonical folder or ~/quest-app):
#   ./scripts/build-appimage.sh [version]
# Requires: flutter build linux --release + cargo build --release already
# done (bundle at flutter_app/build/linux/x64/release/bundle and
# backend/target/release/questctl), and appimagetool at ~/appimagetool-x86_64.AppImage
# (or APPIMAGETOOL=<path>).
# The AppImage bundles the Flutter app AND the questctl release binary
# side by side in usr/bin, so the app finds questctl next to its own
# executable no matter which folder it is started from.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.2.0}"
FLUTTER_APP="$ROOT/flutter_app"
APPDIR="$ROOT/AppDir"
BUNDLE="$FLUTTER_APP/build/linux/x64/release/bundle"
QUESTCTL="$ROOT/backend/target/release/questctl"
APPIMAGETOOL="${APPIMAGETOOL:-$HOME/appimagetool-x86_64.AppImage}"

[ -x "$BUNDLE/reoculus" ] || { echo "missing linux release build: $BUNDLE/reoculus" >&2; exit 1; }
[ -x "$QUESTCTL" ] || { echo "missing release questctl: $QUESTCTL" >&2; exit 1; }
[ -x "$APPIMAGETOOL" ] || { echo "missing appimagetool: $APPIMAGETOOL" >&2; exit 1; }

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$ROOT/releases"

cp -r "$BUNDLE/reoculus" "$BUNDLE/lib" "$BUNDLE/data" "$APPDIR/usr/bin/"
cp "$QUESTCTL" "$APPDIR/usr/bin/questctl"
cp "$FLUTTER_APP/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" "$APPDIR/reoculus.png"

cat > "$APPDIR/reoculus.desktop" <<'EOF'
[Desktop Entry]
Name=ReOculus
Comment=Use your Quest 2 on Linux: manage it, back it up, keep it alive. No Windows, no Meta account.
Exec=reoculus
Icon=reoculus
Terminal=false
Type=Application
Categories=Utility;
StartupWMClass=reoculus
EOF

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/reoculus" "$@"
EOF
chmod +x "$APPDIR/AppRun" "$APPDIR/usr/bin/questctl"

ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$ROOT/releases/QuestCompanion-$VERSION-x86_64.AppImage"
ls -l "$ROOT/releases/QuestCompanion-$VERSION-x86_64.AppImage"
sha256sum "$ROOT/releases/QuestCompanion-$VERSION-x86_64.AppImage"
