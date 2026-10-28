#!/bin/bash
# Variante de build-wimlib.sh : reprend wimlib installé par Homebrew (`brew install wimlib`)
# et le rend autonome dans vendor/ (le binaire cherche libwim à côté de lui).
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX="$(brew --prefix wimlib)"
mkdir -p vendor
cp "$PREFIX/bin/wimlib-imagex" vendor/wimlib-imagex
cp "$PREFIX/lib/libwim.15.dylib" vendor/libwim.15.dylib
cp "$PREFIX/COPYING.GPLv3" vendor/wimlib-COPYING.GPLv3
chmod u+w vendor/wimlib-imagex vendor/libwim.15.dylib
OLD="$(otool -L vendor/wimlib-imagex | awk '/libwim/{print $1}')"
install_name_tool -change "$OLD" @executable_path/libwim.15.dylib vendor/wimlib-imagex
install_name_tool -id @executable_path/libwim.15.dylib vendor/libwim.15.dylib
codesign --force --sign - vendor/libwim.15.dylib vendor/wimlib-imagex 2>/dev/null
otool -L vendor/wimlib-imagex
echo "✅ wimlib $("$PREFIX/bin/wimlib-imagex" --version | head -1 | awk '{print $2}') dans vendor/ ($(lipo -archs vendor/wimlib-imagex))"
