#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE=${1:-"$ROOT_DIR/proflame_wifi_connect.c4z"}
MANIFEST="$ROOT_DIR/scripts/manifest.txt"
NORMALIZED_MTIME=202001010000.00

case "$PACKAGE" in
    /*) ;;
    *) PACKAGE="$(pwd)/$PACKAGE" ;;
esac

[ -f "$MANIFEST" ] || {
    echo "Missing required file: scripts/manifest.txt" >&2
    exit 1
}

FILES=$(sed '/^[[:space:]]*$/d' "$MANIFEST")

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
    find . -type d -exec chmod 0755 {} +
    find . -type f -exec chmod 0644 {} +
    find . -exec touch -t "$NORMALIZED_MTIME" {} +
    zip -X -q "$PACKAGE" $FILES
)

echo "Built $PACKAGE"
