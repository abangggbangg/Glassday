#!/bin/bash
# Builds Glassday.ipa (unsigned) for AltStore to sign with your free Apple ID.
set -e
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project Glassday.xcodeproj -scheme Glassday -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
rm -rf Payload Glassday.ipa
mkdir Payload
cp -R build/Build/Products/Release-iphoneos/Glassday.app Payload/
zip -qr Glassday.ipa Payload
rm -rf Payload
echo "Built $(pwd)/Glassday.ipa — AirDrop it to your iPhone and open it with AltStore."
