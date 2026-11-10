#!/bin/bash
# Builds Glassday.ipa (app + widget) for AltStore / SideStore.
# No paid Apple account needed: AltStore signs the app with your free Apple ID when it installs it.
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Run: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

echo "Building Glassday (this takes a minute)…"
xcodebuild -project Glassday.xcodeproj -scheme Glassday -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build -quiet

APP="build/Build/Products/Release-iphoneos/Glassday.app"
APPEX="$APP/PlugIns/GlassdayWidget.appex"
[ -x "$APP/Glassday" ] || { echo "Error: the app binary is missing from $APP" >&2; exit 1; }
if [ ! -d "$APPEX" ] || [ ! -x "$APPEX/GlassdayWidget" ] || [ ! -f "$APPEX/Info.plist" ]; then
  echo "Error: the widget (GlassdayWidget.appex) is missing or incomplete inside the app." >&2
  echo "Not creating Glassday.ipa. Check the GlassdayWidget target built, then run this again." >&2
  exit 1
fi

rm -rf Payload Glassday.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qry Glassday.ipa Payload
rm -rf Payload

echo "Done: $(pwd)/Glassday.ipa"
echo "AirDrop it to your iPhone (save to Files), then open AltStore → My Apps → + and pick it."
