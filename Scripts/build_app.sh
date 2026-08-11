#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="СОЗВОН"
EXECUTABLE_NAME="CallListenerApp"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

swift build --package-path "$ROOT_DIR" -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/CallListener.icns" "$APP_DIR/Contents/Resources/CallListener.icns"

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

    if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
        SIGN_IDENTITY="$(
            security find-identity -v -p codesigning 2>/dev/null \
                | awk -F '"' '/Apple Development/ { print $2; exit }'
        )"
    fi

    if [[ -n "$SIGN_IDENTITY" ]]; then
        codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
    else
        codesign --force --deep --sign - "$APP_DIR" >/dev/null
    fi
fi

echo "$APP_DIR"
