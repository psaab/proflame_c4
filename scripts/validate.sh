#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE=${1:-"$ROOT_DIR/proflame_wifi_connect.c4z"}
MANIFEST="$ROOT_DIR/scripts/manifest.txt"

case "$PACKAGE" in
    /*) ;;
    *) PACKAGE="$(pwd)/$PACKAGE" ;;
esac

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1"
}

require_file() {
    [ -f "$ROOT_DIR/$1" ] || fail "Missing required file: $1"
}

require_tool xmllint
require_tool unzip
require_tool zip

require_file scripts/manifest.txt

FILES=$(sed '/^[[:space:]]*$/d' "$MANIFEST")

for file in $FILES; do
    require_file "$file"
done

[ -f "$PACKAGE" ] || fail "Missing package: $PACKAGE"

xmllint --noout "$ROOT_DIR/driver.xml"

grep -q '<script file="driver.lua"' "$ROOT_DIR/driver.xml" || fail "driver.xml does not reference driver.lua"
grep -q '<documentation file="www/documentation.html"' "$ROOT_DIR/driver.xml" || fail "driver.xml does not reference www/documentation.html"

# Ensure the committed driver.lua matches what scripts/bundle.sh would produce
# from src/driver.lua + vendor/*.lua. Direct edits to driver.lua are rejected.
require_file src/driver.lua
require_file vendor/JSON.lua
require_file scripts/bundle.sh
BUNDLE_CHECK=$(mktemp)
"$ROOT_DIR/scripts/bundle.sh" "$BUNDLE_CHECK" >/dev/null
cmp -s "$BUNDLE_CHECK" "$ROOT_DIR/driver.lua" || { rm -f "$BUNDLE_CHECK"; fail "driver.lua is out of sync with src/driver.lua + vendor/*.lua; re-run scripts/bundle.sh"; }
rm -f "$BUNDLE_CHECK"

LUA_VERSION=$(sed -n 's/^DRIVER_VERSION = "\(.*\)"/\1/p' "$ROOT_DIR/driver.lua" | head -n 1)
XML_VERSION=$(sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' "$ROOT_DIR/driver.xml" | head -n 1)
SPEC_VERSION=$(sed -n 's/^- \*\*Driver Version\*\*: \([^ ]*\).*/\1/p' "$ROOT_DIR/Proflame_Control4_Driver_Specification.md" | head -n 1)
BUILD_TIMESTAMP=$(sed -n 's/^BUILD_TIMESTAMP = "\(.*\)"/\1/p' "$ROOT_DIR/driver.lua" | head -n 1)

[ -n "$LUA_VERSION" ] || fail "Could not read DRIVER_VERSION from driver.lua"
[ -n "$XML_VERSION" ] || fail "Could not read <version> from driver.xml"
[ -n "$SPEC_VERSION" ] || fail "Could not read Driver Version from Proflame_Control4_Driver_Specification.md"
[ "$LUA_VERSION" = "$XML_VERSION" ] || fail "Version mismatch: driver.lua=$LUA_VERSION driver.xml=$XML_VERSION"
[ "$LUA_VERSION" = "$SPEC_VERSION" ] || fail "Spec version mismatch: driver.lua=$LUA_VERSION spec=$SPEC_VERSION"

EXPECTED=$(mktemp)
ACTUAL=$(mktemp)
trap 'rm -f "$EXPECTED" "$ACTUAL"' EXIT

printf '%s\n' $FILES | sort > "$EXPECTED"

unzip -Z1 "$PACKAGE" | sort > "$ACTUAL"
if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "Expected package contents:" >&2
    cat "$EXPECTED" >&2
    echo "Actual package contents:" >&2
    cat "$ACTUAL" >&2
    fail "Unexpected .c4z contents"
fi

for file in $FILES; do
    unzip -p "$PACKAGE" "$file" | cmp -s - "$ROOT_DIR/$file" || fail "Packaged $file is stale"
done

for ref in \
    "www/documentation.html" \
    "www/icons/device_sm.png" \
    "www/icons/device_lg.png"
do
    require_file "$ref"
done

echo "Validation passed (version $LUA_VERSION, build ${BUILD_TIMESTAMP:-unknown})"
