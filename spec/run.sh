#!/usr/bin/env bash
# Runs all specs (or the given spec files) with LuaJIT + busted.
# Prepare the environment once with spec/setup_env.sh. Exits non-zero when a spec fails.
set -euo pipefail

DEV="${RSSREADER_DEV:-$HOME/rssreader-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUSTED="$(ls -d "$DEV"/lib/luarocks/rocks-5.1/busted/*/bin/busted 2>/dev/null | tail -1)"

if [ ! -x "$DEV/bin/luajit" ] || [ -z "$BUSTED" ] || [ ! -f "$DEV/lua/lua-ljsqlite3/init.lua" ]; then
    echo "spec environment missing; run spec/setup_env.sh first" >&2
    exit 2
fi

# Optional FreshRSS test credentials from a file outside the repo (never committed, never printed).
# Variables already set in the environment win.
WIN_USER="$( (cmd.exe /c 'echo %USERNAME%' </dev/null 2>/dev/null || true) | tr -d '\r')"
CRED_FILE="${RSSREADER_TEST_ENV_FILE:-/mnt/c/Users/${WIN_USER:-unknown}/.rssreader-test.env}"
if [ -z "${RSSREADER_TEST_FRESHRSS_URL:-}" ] && [ -f "$CRED_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    set +a
fi

export LUA_PATH="$ROOT/?.lua;$ROOT/spec/helpers/?.lua;$DEV/lua/?.lua;$DEV/share/lua/5.1/?.lua;$DEV/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$DEV/lib/lua/5.1/?.so;;"

cd "$ROOT"
if [ "$#" -eq 0 ]; then
    set -- spec
fi
exec "$DEV/bin/luajit" "$BUSTED" --helper=spec/helpers/koreader_stubs.lua --output=utfTerminal "$@"
