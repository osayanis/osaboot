#!/bin/bash
# Compile wimlib-imagex (découpe d'install.wim pour les ISO Windows) en binaire autonome,
# sans dépendance externe, dans vendor/. Source officielle, vérifiée par son SHA-256
# (le même que celui de la formule Homebrew). build.sh le met ensuite dans l'app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.14.5
SHA=84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194
OUT=vendor/wimlib-imagex
[ -x "$OUT" ] && { echo "✅ $OUT déjà là"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "https://wimlib.net/downloads/wimlib-$VERSION.tar.gz" -o "$WORK/src.tgz"
echo "$SHA  $WORK/src.tgz" | shasum -a 256 -c -
tar -xzf "$WORK/src.tgz" -C "$WORK"
(
  cd "$WORK/wimlib-$VERSION"
  ./configure --quiet --disable-shared --enable-static --without-fuse --without-ntfs-3g \
      CFLAGS="-O2 -mmacosx-version-min=14.0" >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
)
mkdir -p vendor
cp "$WORK/wimlib-$VERSION/wimlib-imagex" "$OUT"
cp "$WORK/wimlib-$VERSION/COPYING.GPLv3" vendor/wimlib-COPYING.GPLv3
strip "$OUT"
otool -L "$OUT"
echo "✅ $OUT ($(du -h "$OUT" | cut -f1)) — wimlib $VERSION, GPLv3"
