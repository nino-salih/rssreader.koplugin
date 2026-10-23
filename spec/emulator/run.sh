#!/usr/bin/env bash
# KOReader emulator (Linux x86_64 build, same version as the Kindle) with the plugin
# from this repo and local test feeds only (no real account, no credentials).
#
#   spec/emulator/run.sh             interactive window (WSLg), Kindle PW4 size
#   spec/emulator/run.sh SHOTS_DIR   scripted run: fresh DB, sync of the test feeds,
#                                    screenshots of every view into SHOTS_DIR, then quit
#   RSSREADER_EMU_FRESHRSS=1 spec/emulator/run.sh OUT_DIR
#                                    real-server mode: two read-only syncs of the FreshRSS
#                                    test account from an empty DB (no screenshots); the
#                                    redacted log lines go to OUT_DIR/freshrss-sync.log
#   RSSREADER_EMU_FRESHRSS=1 RSSREADER_EMU_IMGPROXY=1 spec/emulator/run.sh OUT_DIR
#                                    the same with the image proxy of
#                                    RSSREADER_TEST_IMGPROXY_URL/_USER/_PASSWORD
#
# Everything lives below $RSSREADER_DEV (default ~/rssreader-dev); nothing system-wide.
set -euo pipefail

DEV="${RSSREADER_DEV:-$HOME/rssreader-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/spec/emulator"
VERSION="v2026.07.1"
KO_DIR="$DEV/koreader-emu"
KO="$KO_DIR/lib/koreader"
DATA="$DEV/emu-home"      # KO_HOME: settings, DB, images of the emulator
CONF="$DEV/emu-config"    # rssreader_configuration.lua / rssreader_local_defaults.lua
WWW="$DEV/emu-www"        # served test feeds and images
LOG="$DEV/emu.log"
PORT=8765
SHOTS="${1:-}"
FRESHRSS="${RSSREADER_EMU_FRESHRSS:-}"

if [ -n "$FRESHRSS" ]; then
    if [ -z "$SHOTS" ]; then
        echo "real-server mode needs an output folder: RSSREADER_EMU_FRESHRSS=1 $0 OUT_DIR" >&2
        exit 2
    fi
    # Credentials as in spec/run.sh: a file outside the repo, never printed. Set variables win.
    WIN_USER="$( (cmd.exe /c 'echo %USERNAME%' </dev/null 2>/dev/null || true) | tr -d '\r')"
    CRED_FILE="${RSSREADER_TEST_ENV_FILE:-/mnt/c/Users/${WIN_USER:-unknown}/.rssreader-test.env}"
    if [ -z "${RSSREADER_TEST_FRESHRSS_URL:-}" ] && [ -f "$CRED_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$CRED_FILE"
        set +a
    fi
    if [ -z "${RSSREADER_TEST_FRESHRSS_URL:-}" ] || [ -z "${RSSREADER_TEST_FRESHRSS_USER:-}" ] \
        || [ -z "${RSSREADER_TEST_FRESHRSS_PASSWORD:-}" ]; then
        echo "RSSREADER_TEST_FRESHRSS_* not set - real-server mode skipped" >&2
        exit 2
    fi
    export RSSREADER_TEST_FRESHRSS_URL RSSREADER_TEST_FRESHRSS_USER RSSREADER_TEST_FRESHRSS_PASSWORD
    export RSSREADER_EMU_FRESHRSS=1
    if [ "${RSSREADER_EMU_IMGPROXY:-}" = "1" ]; then
        if [ -z "${RSSREADER_TEST_IMGPROXY_URL:-}" ] || [ -z "${RSSREADER_TEST_IMGPROXY_USER:-}" ] \
            || [ -z "${RSSREADER_TEST_IMGPROXY_PASSWORD:-}" ]; then
            echo "RSSREADER_TEST_IMGPROXY_* not set - image proxy run skipped" >&2
            exit 2
        fi
        export RSSREADER_TEST_IMGPROXY_URL RSSREADER_TEST_IMGPROXY_USER RSSREADER_TEST_IMGPROXY_PASSWORD
        export RSSREADER_EMU_IMGPROXY=1
    fi
    # Own data dir (the screenshot runs keep theirs) and a temporary config folder.
    # The config reads the credentials from the environment: nothing is written to disk.
    DATA="$DEV/emu-home-freshrss"
    LOG="$DEV/emu-freshrss.log"
    mkdir -p "$DEV"
    CONF="$(mktemp -d "$DEV/emu-config-freshrss.XXXXXX")"
fi

if [ ! -x "$KO/reader.lua" ]; then
    mkdir -p "$KO_DIR"
    curl -sSL -o "$KO_DIR/koreader.tar.xz" \
        "https://github.com/koreader/koreader/releases/download/$VERSION/koreader-linux-x86_64-$VERSION.tar.xz"
    tar -xJf "$KO_DIR/koreader.tar.xz" -C "$KO_DIR"
fi

mkdir -p "$DATA/plugins" "$CONF" "$WWW"
ln -sfn "$ROOT" "$DATA/plugins/rssreader.koplugin"
ln -sfn "$HERE/rssreader_emu.koplugin" "$DATA/plugins/rssreader_emu.koplugin"
# RSSREADER_EMU_SIMPLEUI=1: with the SimpleUI plugin (git clone below $DEV, outside the
# repo), onboarding marked done so its first-run dialog does not cover the screenshots.
if [ "${RSSREADER_EMU_SIMPLEUI:-}" = "1" ]; then
    if [ ! -d "$DEV/simpleui.koplugin" ]; then
        git clone --depth 1 https://github.com/doctorhetfield-cmd/simpleui.koplugin "$DEV/simpleui.koplugin"
    fi
    ln -sfn "$DEV/simpleui.koplugin" "$DATA/plugins/simpleui.koplugin"
    mkdir -p "$DATA/settings/simpleui"
    if [ ! -f "$DATA/settings/simpleui/sui_settings.lua" ]; then
        printf 'return {\n    ["simpleui_onboarding_done"] = true,\n}\n' > "$DATA/settings/simpleui/sui_settings.lua"
    fi
    export RSSREADER_EMU_SIMPLEUI
else
    rm -f "$DATA/plugins/simpleui.koplugin"
fi

SERVER=""
cleanup() {
    if [ -n "$SERVER" ]; then
        kill "$SERVER" 2>/dev/null || true
    fi
    if [ -n "$FRESHRSS" ]; then
        rm -rf "$CONF"
    fi
}
trap cleanup EXIT

if [ -n "$FRESHRSS" ]; then
    cp "$HERE/config/emu_freshrss_configuration.lua" "$CONF/rssreader_configuration.lua"
else
    cp "$HERE/config/emu_configuration.lua" "$CONF/rssreader_configuration.lua"
    cp "$HERE/config/emu_local_defaults.lua" "$CONF/rssreader_local_defaults.lua"
    python3 "$HERE/make_feeds.py" "$WWW" "http://127.0.0.1:$PORT"
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" >/dev/null 2>&1 &
    SERVER=$!
fi

if [ -n "$SHOTS" ]; then
    mkdir -p "$SHOTS"
    rm -f "$SHOTS"/*.png
    rm -rf "$DATA/rssreader_offline.sqlite3" "$DATA/rssreader_offline"
fi

cd "$KO"
KO_HOME="$DATA" \
LUA_PATH="$CONF/?.lua;;" \
EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 \
RSSREADER_EMU_SHOTS="$SHOTS" \
    ./reader.lua > "$LOG" 2>&1 || true

if [ -n "$FRESHRSS" ]; then
    # Server addresses and accounts never stay in the log (image URLs or error
    # texts may contain the server address).
    perl -pi -e '
        BEGIN {
            @secrets = grep { length } map { $ENV{$_} // "" }
                qw(RSSREADER_TEST_FRESHRSS_URL RSSREADER_TEST_FRESHRSS_USER RSSREADER_TEST_FRESHRSS_PASSWORD
                   RSSREADER_TEST_IMGPROXY_URL RSSREADER_TEST_IMGPROXY_USER RSSREADER_TEST_IMGPROXY_PASSWORD);
            for my $name (qw(RSSREADER_TEST_FRESHRSS_URL RSSREADER_TEST_IMGPROXY_URL)) {
                push @secrets, $1 if ($ENV{$name} // "") =~ m{^\w+://([^/:?#]+)};
            }
            @secrets = sort { length($b) <=> length($a) } @secrets;
        }
        for my $secret (@secrets) { s/\Q$secret\E/<redacted>/g }' "$LOG"
    grep -E "EMU|RSSReader sync|too large|card image of|image proxy|ERROR|error" "$LOG" > "$SHOTS/freshrss-sync.log" || true
    # Image bytes on the device after both syncs (originals and card copies).
    IMAGES="$DATA/rssreader_offline/images"
    if [ -d "$IMAGES" ]; then
        echo "EMU images on disk: $(find "$IMAGES" -type f | wc -l) files, $(du -sb "$IMAGES" | cut -f1) bytes" \
            "(image proxy: ${RSSREADER_EMU_IMGPROXY:-0})" >> "$SHOTS/freshrss-sync.log"
    fi
    grep -E "EMU freshrss|EMU images|sync images total|image proxy|ERROR" "$SHOTS/freshrss-sync.log" | tail -20 || true
elif [ -n "$SHOTS" ]; then
    grep -E "EMU|RSSReader|ERROR|error" "$LOG" | tail -40 || true
    ls "$SHOTS"
fi
