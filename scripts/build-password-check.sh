#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc Sources/ScreenLink/LocalPasswordVerifier.swift Tools/PasswordCheck/main.swift \
    -o dist/ScreenLinkPasswordCheck
/usr/bin/codesign --force --sign - dist/ScreenLinkPasswordCheck
/usr/bin/codesign --verify --strict dist/ScreenLinkPasswordCheck
