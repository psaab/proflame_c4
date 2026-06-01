#!/usr/bin/env sh
# Run every test/test_*.lua file under lua5.1 and aggregate pass/fail. Each
# test loads the C4 shim, then dofile()s the bundled driver.lua at repo root.
# The bundle is regenerated before the run so tests always reflect the
# current src/ + vendor/ source of truth.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

command -v lua >/dev/null 2>&1 || {
    echo "Missing required tool: lua (Lua 5.1 interpreter)" >&2
    exit 1
}

# Regenerate driver.lua so tests see the current sources. Skip if bundle.sh
# isn't executable (e.g., readonly checkouts); the existing driver.lua is
# whatever the working tree last produced.
if [ -x "$ROOT_DIR/scripts/bundle.sh" ]; then
    "$ROOT_DIR/scripts/bundle.sh" >/dev/null
fi

# Pre-glob check so a typo in the pattern doesn't silently produce zero tests.
set +e
tests_glob=$(ls "$SCRIPT_DIR"/test_*.lua 2>/dev/null)
set -e
if [ -z "$tests_glob" ]; then
    echo "No tests found matching $SCRIPT_DIR/test_*.lua" >&2
    exit 1
fi

pass=0
fail=0
failed_names=""

for test_file in "$SCRIPT_DIR"/test_*.lua; do
    name=$(basename "$test_file" .lua)
    # Each test runs in its own Lua process so global state doesn't leak.
    # LUA_PATH lets `require("c4_shim")` find the shim alongside the tests.
    # cd to repo root so dofile("driver.lua") resolves correctly.
    if (cd "$ROOT_DIR" && LUA_PATH="$SCRIPT_DIR/?.lua;;" lua "$test_file" >/tmp/proflame_test_$$.out 2>&1); then
        printf "PASS  %s\n" "$name"
        pass=$((pass + 1))
    else
        printf "FAIL  %s\n" "$name"
        sed 's/^/        /' /tmp/proflame_test_$$.out
        fail=$((fail + 1))
        failed_names="$failed_names $name"
    fi
    rm -f /tmp/proflame_test_$$.out
done

echo "----"
printf "%d total, %d pass, %d fail\n" $((pass + fail)) "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    echo "Failed:$failed_names" >&2
    exit 1
fi
