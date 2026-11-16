#!/bin/bash
# Bouwt Infinity Prompt.app en zet hem in Apps/ in de vault-root, in Programma's en in iCloud (update voor de andere Mac).
# Elke geslaagde build gaat in git en naar GitHub (als er een remote is).
# Gebruik: ./bouw.sh          echte build, buildnummer +1
#          ./bouw.sh proef    alleen bouwen naar /tmp, niets bijwerken
set -e
cd "$(dirname "$0")"
HIER="$PWD"
APP="$HIER/../../../Apps/Infinity Prompt.app"
SLEUTEL="$HOME/Library/Application Support/Infinity Frame/Infinity Prompt/update-sleutel"
WOLK="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Infinity Frame/Apps/Infinity Prompt"
TMP="$(mktemp -d)"
NIEUW="$TMP/Infinity Prompt.app"
PROEF=0; [ "$1" = "proef" ] && PROEF=1

# Eerst in een tijdelijke map bouwen. Mislukt het, dan blijft de werkende app staan.
mkdir -p "$NIEUW/Contents/MacOS" "$NIEUW/Contents/Resources/nl.lproj"
BRON=(Model.swift App.swift MainWindow.swift PrompterView.swift ExternalScreen.swift Remote.swift Updater.swift Voice.swift StressTest.swift)
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 "${BRON[@]}" -o "$NIEUW/Contents/MacOS/InfinityPrompt"

# Icoon
swift icoon.swift "$TMP/icoon.png"
mkdir "$TMP/AppIcon.iconset"
for m in 16 32 128 256 512; do
  sips -z $m $m "$TMP/icoon.png" --out "$TMP/AppIcon.iconset/icon_${m}x${m}.png" >/dev/null
  sips -z $((m*2)) $((m*2)) "$TMP/icoon.png" --out "$TMP/AppIcon.iconset/icon_${m}x${m}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$NIEUW/Contents/Resources/AppIcon.icns"
touch "$NIEUW/Contents/Resources/nl.lproj/.gitkeep"

# Buildnummer: alleen een echte build telt.
if [ $PROEF = 0 ]; then
  B="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((B+1))" Info.plist
fi
VERSIE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
cp Info.plist "$NIEUW/Contents/Info.plist"
PUBLIEK="$(swift teken.swift -sleutel "$SLEUTEL" publiek 2>/dev/null || true)"
[ -n "$PUBLIEK" ] && /usr/libexec/PlistBuddy -c "Add :InfinityPromptUpdateKey string $PUBLIEK" "$NIEUW/Contents/Info.plist"
printf 'APPL????' > "$NIEUW/Contents/PkgInfo"
xattr -cr "$NIEUW"
codesign --force --sign - "$NIEUW"

if [ $PROEF = 1 ]; then
  rm -rf "/tmp/Infinity Prompt.app"; cp -R "$NIEUW" "/tmp/Infinity Prompt.app"
  echo "Proefbuild: /tmp/Infinity Prompt.app"; rm -rf "$TMP"; exit 0
fi

rm -rf "$APP"; cp -R "$NIEUW" "$APP"
echo "Gebouwd: $VERSIE (build $BUILD)"
rm -rf "/Applications/Infinity Prompt.app"; cp -R "$NIEUW" "/Applications/Infinity Prompt.app"
echo "Programma's bijgewerkt"

# Update voor de andere Mac. versie.txt komt als laatste.
if mkdir -p "$WOLK" 2>/dev/null && ditto -c -k --keepParent "$NIEUW" "$WOLK/Infinity Prompt.zip.tmp" 2>/dev/null; then
  mv -f "$WOLK/Infinity Prompt.zip.tmp" "$WOLK/Infinity Prompt.zip"
  swift teken.swift -sleutel "$SLEUTEL" teken "$WOLK/Infinity Prompt.zip" > "$WOLK/Infinity Prompt.zip.sig" || echo "Let op: update niet ondertekend" >&2
  echo "$VERSIE $BUILD" > "$WOLK/versie.txt"
  echo "In iCloud gezet voor de andere Mac"
else
  echo "Let op: kon de update niet in iCloud Drive zetten" >&2
fi

# Broncode als tekst voor de Mac Mini (Obsidian Sync neemt alleen tekst betrouwbaar mee).
{
  echo "# Infinity Prompt, broncode (build $BUILD)"
  echo
  echo "Op een andere Mac: maak de map teleprompter, zet elk blok hieronder in een bestand met die naam, en draai ./bouw.sh."
  for f in "${BRON[@]}" icoon.swift teken.swift bouw.sh Info.plist; do
    echo; echo "## $f"; echo; echo '````'; cat "$f"; echo '````'
  done
} > "Broncode (voor de andere Mac).md"

# Git en GitHub
if [ -d "$HIER/.git" ]; then
  git -C "$HIER" add -A
  git -C "$HIER" -c user.name="Alexander de Wit" -c user.email="alexander@infinityframe.nl" \
    commit -q -m "Build $BUILD ($VERSIE)" >/dev/null 2>&1 && echo "Vastgelegd in git: build $BUILD"
  if git -C "$HIER" remote get-url origin >/dev/null 2>&1; then
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git -C "$HIER" push -q origin main 2>/dev/null \
      && echo "Op GitHub gezet" || echo "Let op: GitHub niet bereikt, de volgende build probeert het opnieuw" >&2
  fi
fi
rm -rf "$TMP"
