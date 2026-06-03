#!/usr/bin/env sh
# Bundle src/driver.lua + vendor/*.lua into the single driver.lua that ships
# inside the .c4z. The bundled file at repo root is the deployment artifact;
# src/ and vendor/ are the source of truth.
#
# Vendored libraries are spliced into src/driver.lua at sentinel lines of the
# form `-- BUNDLE_INSERT path/to/file.lua`. Each sentinel is replaced with the
# file's contents (minus its final `return X` statement) wrapped in a
# `do ... end` block that assigns the library to its expected global.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT_DIR/src/driver.lua"
# Optional first argument overrides the output location. Defaults to the
# checked-in driver.lua at repo root.
OUT=${1:-"$ROOT_DIR/driver.lua"}

[ -f "$SRC" ] || { echo "Missing source: $SRC" >&2; exit 1; }

# Map sentinel -> (vendor file, global name that the library returns)
# Add additional libraries here as they're vendored (T1+ work).
#
# Two splicing helpers:
#   bundle_one          — vendor file ends with `return <expr>`; the splicer
#                          assigns that expression to a named global so callers
#                          in driver.lua reach the library by global name.
#   bundle_one_noreturn — vendor file has NO trailing `return`; it registers
#                          its API by mutating top-level globals (functions,
#                          tables) directly. The splicer drops the body inside
#                          a `do ... end` block with no assignment.
#
# Some vendored Snap One modules (drivers-common-public/global/{lib,timer,
# handlers}) require()-import each other at the top of the file. Inside the
# bundled context there is no module loader, so src/driver.lua installs a
# small `require` shim (see the "Snap One require shim" block) that returns
# the matching already-bundled global by string key. The shim is co-located
# with the sentinels rather than spliced by bundle.sh because keeping it in
# src/driver.lua makes the contract auditable from the source of truth.
bundle_one() {
    sentinel=$1
    vendor_path=$2
    global_name=$3
    vendor_full="$ROOT_DIR/$vendor_path"

    [ -f "$vendor_full" ] || { echo "Missing vendor file: $vendor_full" >&2; exit 1; }

    # Require exact-line match so a Lua string literal that happens to contain
    # the sentinel text can never be substituted by accident.
    count=$(awk -v s="$sentinel" '$0 == s { n++ } END { print n+0 }' "$SRC")
    if [ "$count" != "1" ]; then
        echo "Sentinel '$sentinel' must appear exactly once as a full line in src/driver.lua (found $count)" >&2
        exit 1
    fi

    # Strip the trailing `return ...` (or bare `return`) from the vendor file.
    # We assume the vendor lib ends with a single top-level return statement.
    return_line=$(grep -nE "^return([[:space:]]+.*)?$" "$vendor_full" | tail -n 1 | cut -d: -f1)
    if [ -z "$return_line" ]; then
        echo "Could not find a top-level 'return' in $vendor_path" >&2
        exit 1
    fi
    return_expr=$(sed -n "${return_line}p" "$vendor_full" | sed -E 's/^return([[:space:]]+|$)//')
    # A bare `return` (no expression) means the vendor lib returns nil; assign
    # nil to the global so callers get a clear failure rather than a phantom.
    [ -n "$return_expr" ] || return_expr="nil"

    # Build the wrapped block in a temp file: do + vendor body (excluding the
    # return line) + global assignment + end.
    block=$(mktemp)
    {
        echo "-- ===== BUNDLED FROM $vendor_path ====="
        echo "do"
        # Lines 1..(return_line-1) of vendor file
        head -n $((return_line - 1)) "$vendor_full"
        echo "$global_name = $return_expr"
        echo "end"
        echo "-- ===== END BUNDLED $vendor_path ====="
    } > "$block"

    # Splice block into src in place of the sentinel line (exact match).
    awk -v sentinel="$sentinel" -v block="$block" '
        $0 == sentinel {
            while ((getline line < block) > 0) print line
            close(block)
            next
        }
        { print }
    ' "$SRC" > "$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
    rm -f "$block"
}

bundle_one_noreturn() {
    sentinel=$1
    vendor_path=$2
    vendor_full="$ROOT_DIR/$vendor_path"

    [ -f "$vendor_full" ] || { echo "Missing vendor file: $vendor_full" >&2; exit 1; }

    # Require exact-line match so a Lua string literal that happens to contain
    # the sentinel text can never be substituted by accident.
    count=$(awk -v s="$sentinel" '$0 == s { n++ } END { print n+0 }' "$SRC")
    if [ "$count" != "1" ]; then
        echo "Sentinel '$sentinel' must appear exactly once as a full line in src/driver.lua (found $count)" >&2
        exit 1
    fi

    # Build the wrapped block: do + full vendor body + end. The vendor file
    # is expected to register its public surface via top-level global writes
    # (functions or tables), so we do NOT emit any name = ... assignment.
    block=$(mktemp)
    {
        echo "-- ===== BUNDLED FROM $vendor_path ====="
        echo "do"
        cat "$vendor_full"
        echo "end"
        echo "-- ===== END BUNDLED $vendor_path ====="
    } > "$block"

    awk -v sentinel="$sentinel" -v block="$block" '
        $0 == sentinel {
            while ((getline line < block) > 0) print line
            close(block)
            next
        }
        { print }
    ' "$SRC" > "$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
    rm -f "$block"
}

# Start with src/driver.lua, then run each bundle step (each subsequent call
# reads from $OUT and writes back). For now there is only one vendored lib.
cp "$SRC" "$OUT"
SRC="$OUT"  # Subsequent bundle_one calls splice into the in-progress output.

bundle_one "-- BUNDLE_INSERT vendor/JSON.lua"           "vendor/JSON.lua"           "JSON"
bundle_one "-- BUNDLE_INSERT vendor/logging.lua"        "vendor/logging.lua"        "log"
bundle_one "-- BUNDLE_INSERT vendor/persist.lua"        "vendor/persist.lua"        "persist"
bundle_one "-- BUNDLE_INSERT vendor/deferred.lua"       "vendor/deferred.lua"       "deferred"
bundle_one "-- BUNDLE_INSERT vendor/version.lua"        "vendor/version.lua"        "version_lib"
bundle_one "-- BUNDLE_INSERT vendor/lib_helpers.lua"    "vendor/lib_helpers.lua"    "lib_helpers"
bundle_one "-- BUNDLE_INSERT vendor/http.lua"           "vendor/http.lua"           "http_client"
bundle_one "-- BUNDLE_INSERT vendor/github_updater.lua" "vendor/github_updater.lua" "github_updater"

# C1 Phase 1: vendored Snap One drivers-common-public WebSocket module + its
# transitive Lua dependencies. The five files below are byte-identical to
# upstream master (see README.md "Vendored libraries" for the commit SHA). They
# are spliced in dependency order: lib -> timer -> metrics -> handlers ->
# websocket. lib/timer/handlers have no trailing `return` (they register their
# API by mutating top-level globals), so they go through bundle_one_noreturn.
# metrics returns metricsObject and websocket returns wsObject, so they go
# through bundle_one with global names Metrics / WebSocket — those names are
# the exact upstream contract (handlers.lua reads them as bare globals).
#
# Phase 1 is inert: nothing in driver.lua calls into wsObject/Metrics yet, so
# the bundled code is dead weight that must merely load without crashing.
# Phase 2 will replace the hand-rolled WebSocket helpers in src/driver.lua
# with calls into WebSocket:new(...) and drop the static binding from
# driver.xml so the framework can allocate it dynamically.
bundle_one_noreturn "-- BUNDLE_INSERT vendor/drivers-common-public/global/lib.lua"        "vendor/drivers-common-public/global/lib.lua"
bundle_one_noreturn "-- BUNDLE_INSERT vendor/drivers-common-public/global/timer.lua"      "vendor/drivers-common-public/global/timer.lua"
bundle_one          "-- BUNDLE_INSERT vendor/drivers-common-public/module/metrics.lua"    "vendor/drivers-common-public/module/metrics.lua"    "Metrics"
bundle_one_noreturn "-- BUNDLE_INSERT vendor/drivers-common-public/global/handlers.lua"   "vendor/drivers-common-public/global/handlers.lua"
bundle_one          "-- BUNDLE_INSERT vendor/drivers-common-public/module/websocket.lua"  "vendor/drivers-common-public/module/websocket.lua"  "WebSocket"

# Prepend a header so anyone reading driver.lua sees this is generated.
header=$(mktemp)
{
    echo "-- =============================================================================="
    echo "-- THIS FILE IS GENERATED by scripts/bundle.sh."
    echo "-- DO NOT EDIT driver.lua directly. Edit src/driver.lua or vendor/*.lua."
    echo "-- =============================================================================="
    cat "$OUT"
} > "$header"
mv "$header" "$OUT"

echo "Bundled $OUT"
