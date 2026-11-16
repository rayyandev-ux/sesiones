#!/bin/bash
# Compila la app en modo release, arma "Temperas Cremosas.app" y la instala en /Applications.
# El proyecto y el programa siguen llamándose Sesiones; el nombre que se ve es Temperas Cremosas.
# El identificador (pe.rayyan.sesiones) no cambia: así se conservan pestañas, grupos, tema y permisos.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
NOMBRE="Temperas Cremosas"
APP="build/$NOMBRE.app"
VERSION=0.5.1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sesiones "$APP/Contents/MacOS/Sesiones"
strip -x "$APP/Contents/MacOS/Sesiones" 2>/dev/null || true
# el ícono va como Logo.icns: un nombre nuevo hace que macOS no use el ícono viejo que tenía guardado
cp recursos/Sesiones.icns "$APP/Contents/Resources/Logo.icns"
cp recursos/fuentes/*.ttf recursos/fuentes/*.woff2 "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NOMBRE</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleDisplayName</key><string>$NOMBRE</string>
  <key>CFBundleIdentifier</key><string>pe.rayyan.sesiones</string>
  <key>CFBundleExecutable</key><string>Sesiones</string>
  <key>CFBundleIconFile</key><string>Logo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Para dictarle a Claude con tu voz (mantén fn y habla).</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Para convertir lo que dices en texto dentro de la terminal.</string>
</dict></plist>
PLIST
# Firma: sin nada, firma local (ad-hoc). Con un certificado tuyo, macOS recuerda el permiso del micrófono
# entre versiones: pon su hash en SESIONES_FIRMA o en un archivo .firma (no se sube al repo).
#   security find-identity -v -p codesigning
FIRMA="${SESIONES_FIRMA:-$(cat .firma 2>/dev/null)}"
codesign --force --sign "${FIRMA:--}" "$APP"
if [ "${1:-}" != "--sin-instalar" ]; then
  # no se cierra la app abierta (puede tener sesiones trabajando): la nueva versión entra al volver a abrirla
  rm -rf "/Applications/$NOMBRE.app"
  rm -rf /Applications/Sesiones.app # el nombre de antes (2026-11-16): que no queden dos copias
  cp -R "$APP" /Applications/
  # una sola copia: la de /Applications (la de build/ no se queda, para no abrirla ni fijarla en el Dock por error)
  rm -rf "$APP"
  echo "Instalada en /Applications/$NOMBRE.app"
  pgrep -x Sesiones >/dev/null && echo "La app está abierta: toca «Actualizar» arriba a la derecha (o ciérrala con ⌘Q y ábrela)." || true
fi
