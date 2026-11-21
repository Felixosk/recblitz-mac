#!/bin/bash
set -euo pipefail

# Builds RecBlitz.app: compiles the Swift package for both architectures,
# assembles a proper .app bundle (Info.plist with the microphone, camera and
# screen-recording texts, no dock icon, pipeline.py as a resource) and signs it.

cd "$(dirname "$0")"

APP_NAME="RecBlitz"
BUNDLE_ID="app.recblitz.RecBlitz"
VERSION="3.0"
BUILD_NUMBER="21"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# ---------------------------------------------------------------------------
# Lint (Runde 18): Quelltext-Waechter in tools/lint.py. Keine losen Zahlen ausserhalb Theme.swift,
# Hinweistexte nur ueber ThemeNote (brechen um statt abgeschnitten zu werden), keine Move-Transitions.
# ---------------------------------------------------------------------------
echo "==> Quelltext pruefen (tools/lint.py)"
python3 tools/lint.py || exit 1

echo "==> Pipeline-Selbsttest"
python3 pipeline.py --selftest

echo "==> Compiling ($APP_NAME, universal arm64 + x86_64)"
# Universal Binary, damit die App auch auf Intel-Macs laeuft. Die Command Line
# Tools koennen nicht beide Architekturen in einem Lauf, also getrennt bauen
# und mit lipo zusammenfuegen.
swift build -c release --arch arm64
swift build -c release --arch x86_64
BIN=".build/universal-$APP_NAME"
lipo -create ".build/arm64-apple-macosx/release/$APP_NAME" \
             ".build/x86_64-apple-macosx/release/$APP_NAME" \
     -output "$BIN"
echo "==> Architectures: $(lipo -archs "$BIN")"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp pipeline.py "$APP/Contents/Resources/pipeline.py"
cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RecBlitz records your voice note and transcribes it on this Mac.</string>
    <key>NSCameraUsageDescription</key>
    <string>RecBlitz shows you as a round webcam bubble inside your screen recording.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>RecBlitz turns your recording into text on this Mac.</string>
</dict>
</plist>
PLIST

echo "==> Code signing"
# Signieren mit einem stabilen selbstsignierten Zertifikat, falls konfiguriert.
# WARUM: Ad-hoc-Signaturen ("--sign -") aendern die Identitaet der App bei JEDEM
# Build. macOS haelt sie dann fuer eine andere App und wirft alle erteilten
# Berechtigungen weg (Mikrofon, Bildschirmaufnahme, Kamera), man erlaubt es
# neu, baut einmal, und es ist wieder kaputt. Mit einem festen Zertifikat lautet
# die Designated Requirement "identifier + certificate leaf" und bleibt ueber
# Rebuilds gleich, damit bleiben auch die Freigaben erhalten.
#
# Die Zertifikatsdaten stehen NICHT hier, sondern in einer lokalen, nicht
# versionierten Datei signing.local (Vorlage: signing.local.example).
# Ohne diese Datei signiert das Skript ad-hoc, das genuegt zum Ausprobieren.
[ -f "signing.local" ] && . ./signing.local
SIGN_ID="${SIGN_ID:-}"
# Fingerabdruck mitpruefen, nicht nur den Namen. Liegen im Schluesselbund
# ZWEI gleichnamige Zertifikate, aendert sich die Designated Requirement und
# alle Berechtigungen sind still kaputt, obwohl in den Systemeinstellungen der
# Haken steht.
SIGN_SHA1="${SIGN_SHA1:-}"
FOUND_SHA1=""
if [ -n "$SIGN_ID" ]; then
    # `|| true`: ohne Treffer liefert security Exit 44, und set -euo pipefail
    # wuerde das Skript auf jedem fremden Mac wortlos beenden.
    FOUND_SHA1=$(security find-certificate -c "$SIGN_ID" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}' || true)
fi
if [ -n "$FOUND_SHA1" ] && [ -n "$SIGN_SHA1" ] && [ "$FOUND_SHA1" != "$SIGN_SHA1" ]; then
    echo "    FEHLER: Zertifikat '$SIGN_ID' hat den falschen Fingerabdruck."
    echo "            erwartet: $SIGN_SHA1"
    echo "            gefunden: $FOUND_SHA1"
    echo "            Ein zweites gleichnamiges Zertifikat wuerde alle App-"
    echo "            Berechtigungen unbrauchbar machen. Pruefe den"
    echo "            Schluesselbund auf Duplikate."
    exit 1
fi
if [ -n "$FOUND_SHA1" ]; then
    codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
    echo "    (ad-hoc signiert. Fuer stabile Berechtigungen siehe signing.local.example)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || \
        codesign --force --sign - "$APP"
fi

# Selbsttest der reinen Logik. Ersetzt ein Test-Target, denn XCTest gehoert
# zu Xcode und nicht zu den Command Line Tools.
echo "==> Selbsttest"
if ! "$APP/Contents/MacOS/$APP_NAME" --selftest; then
    echo "    ABGEBROCHEN: Selbsttest fehlgeschlagen (siehe oben)."
    exit 1
fi

echo "==> Done: $APP"
echo "    Starten:      open \"$PWD/$APP\""
echo "    Installieren: cp -R \"$PWD/$APP\" /Applications/"
