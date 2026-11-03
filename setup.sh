#!/bin/bash
# Generates Glassday.xcodeproj and opens it in Xcode.
set -e
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode isn't set up yet. Install Xcode from the App Store, open it once, then run this again."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew…"
    brew install xcodegen
  else
    echo "XcodeGen is needed. Install Homebrew from https://brew.sh, then run: brew install xcodegen"
    exit 1
  fi
fi

xcodegen generate
open Glassday.xcodeproj
echo "Done. In Xcode, set your Team for both targets, pick your iPhone, and press Run."
