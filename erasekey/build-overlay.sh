#!/bin/bash
# Construit l'ajout d'OsaBoot à ShredOS : un petit initrd (cpio) que GRUB charge après le
# noyau. Ses fichiers remplacent ceux de ShredOS au démarrage :
#   /usr/bin/osa-erase       l'interface EraseKEY (Go, Linux x86-64, sans dépendance)
#   /usr/bin/nwipe_launcher  le lanceur de ShredOS, identique sauf qu'il lance osa-erase
#                            à la place de l'écran de nwipe
# Le lanceur est pris dans la version de ShredOS qu'OsaBoot télécharge (SHREDOS_TAG) :
# il doit lui correspondre exactement.
#   ./build-overlay.sh [sortie.cpio.gz]
set -euo pipefail
# chemin de sortie résolu avant de changer de dossier
OUT="${1:-$(dirname "$0")/build/erasekey-overlay.cpio.gz}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
cd "$(dirname "$0")"

SHREDOS_TAG="v2025.11_32_x86-64_0.43.1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/usr/bin"

command -v go >/dev/null || { echo "Go est nécessaire (brew install go)."; exit 1; }
# version : celle d'OsaBoot quand le dossier est dans OsaBoot, sinon OSA_VERSION ou « dev »
VERSION="${OSA_VERSION:-$(sed -n "s/.*ShortVersionString<\/key><string>\([^<]*\).*/\1/p" ../build.sh 2>/dev/null)}"; VERSION="${VERSION:-dev}"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$WORK/root/usr/bin/osa-erase" .

LAUNCHER_URL="https://raw.githubusercontent.com/PartialVolume/shredos.x86_64/$SHREDOS_TAG/board/shredos/fsoverlay/usr/bin/nwipe_launcher"
curl -fsSL "$LAUNCHER_URL" -o "$WORK/nwipe_launcher"
# les deux lignes qui lancent nwipe ; on refuse si le lanceur ne ressemble plus à ce qu'on connaît
COUNT=$(grep -c '^\s*/usr/bin/nwipe --logfile=\$logfile \$launcher_options' "$WORK/nwipe_launcher" || true)
[ "$COUNT" = "2" ] || { echo "Le lanceur de ShredOS $SHREDOS_TAG a changé ($COUNT lignes nwipe) : à revoir."; exit 1; }
sed -E 's#^([[:space:]]*)/usr/bin/nwipe --logfile=\$logfile \$launcher_options.*$#\1/usr/bin/osa-erase --logfile=$logfile $exclude_boot_disc_cmd#' "$WORK/nwipe_launcher" > "$WORK/root/usr/bin/nwipe_launcher"
[ "$(grep -c '/usr/bin/osa-erase' "$WORK/root/usr/bin/nwipe_launcher")" = "2" ] || { echo "Retouche du lanceur ratée."; exit 1; }
chmod 755 "$WORK/root/usr/bin/osa-erase" "$WORK/root/usr/bin/nwipe_launcher"

# cpio « newc », fichiers à root
(cd "$WORK/root" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9 > "$OUT")
echo "✅ $(basename "$OUT") ($(du -h "$OUT" | cut -f1)) pour ShredOS $SHREDOS_TAG"
