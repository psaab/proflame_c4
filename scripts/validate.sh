#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT_DIR/proflame_wifi_connect.c4z"

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

for file in \
    driver.xml \
    driver.lua \
    www/documentation.html \
    www/icons/device_sm.png \
    www/icons/device_lg.png
do
    require_file "$file"
done

require_file proflame_wifi_connect.c4z

xmllint --noout "$ROOT_DIR/driver.xml"

grep -q '<script file="driver.lua"' "$ROOT_DIR/driver.xml" || fail "driver.xml does not reference driver.lua"
grep -q '<documentation file="www/documentation.html"' "$ROOT_DIR/driver.xml" || fail "driver.xml does not reference www/documentation.html"

LUA_VERSION=$(sed -n 's/^DRIVER_VERSION = "\(.*\)"/\1/p' "$ROOT_DIR/driver.lua" | head -n 1)
XML_VERSION=$(sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' "$ROOT_DIR/driver.xml" | head -n 1)
BUILD_TIMESTAMP=$(sed -n 's/^BUILD_TIMESTAMP = "\(.*\)"/\1/p' "$ROOT_DIR/driver.lua" | head -n 1)

[ -n "$LUA_VERSION" ] || fail "Could not read DRIVER_VERSION from driver.lua"
[ -n "$XML_VERSION" ] || fail "Could not read <version> from driver.xml"
[ "$LUA_VERSION" = "$XML_VERSION" ] || fail "Version mismatch: driver.lua=$LUA_VERSION driver.xml=$XML_VERSION"

EXPECTED=$(mktemp)
ACTUAL=$(mktemp)
trap 'rm -f "$EXPECTED" "$ACTUAL"' EXIT

cat > "$EXPECTED" <<'EOF'
driver.lua
driver.xml
www/documentation.html
www/icons/device_lg.png
www/icons/device_sm.png
EOF

unzip -Z1 "$PACKAGE" | sort > "$ACTUAL"
if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "Expected package contents:" >&2
    cat "$EXPECTED" >&2
    echo "Actual package contents:" >&2
    cat "$ACTUAL" >&2
    fail "Unexpected .c4z contents"
fi

for file in driver.xml driver.lua www/documentation.html www/icons/device_sm.png www/icons/device_lg.png; do
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
