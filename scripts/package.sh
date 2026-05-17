#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE=${1:-"$ROOT_DIR/proflame_wifi_connect.c4z"}

FILES="
driver.xml
driver.lua
www/documentation.html
www/icons/device_sm.png
www/icons/device_lg.png
"

for file in $FILES; do
    if [ ! -f "$ROOT_DIR/$file" ]; then
        echo "Missing required file: $file" >&2
        exit 1
    fi
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/www/icons"
for file in $FILES; do
    mkdir -p "$TMP_DIR/$(dirname "$file")"
    cp -p "$ROOT_DIR/$file" "$TMP_DIR/$file"
done

rm -f "$PACKAGE"
(
    cd "$TMP_DIR"
    zip -X -q "$PACKAGE" driver.xml driver.lua www/documentation.html www/icons/device_sm.png www/icons/device_lg.png
)

echo "Built $PACKAGE"
