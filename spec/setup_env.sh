#!/usr/bin/env bash
# One-time setup of the spec environment without root rights.
# Builds LuaJIT + LuaRocks into $RSSREADER_DEV (default ~/rssreader-dev),
# installs busted and fetches lua-ljsqlite3 (KOReader copy) next to it.
# Needs gcc, make, curl, git and the system libsqlite3 (package libsqlite3-0).
set -euo pipefail

DEV="${RSSREADER_DEV:-$HOME/rssreader-dev}"
LUAJIT_REF="${LUAJIT_REF:-v2.1}"
LUAROCKS_VERSION="${LUAROCKS_VERSION:-3.11.1}"
# lua-ljsqlite3 lives in koreader-base; this commit is the base submodule of KOReader v2026.07.1.
KOBASE_SHA="${KOBASE_SHA:-6e4bc81af4e04f78d81677a323a780a71b29702a}"

mkdir -p "$DEV/src"
cd "$DEV/src"

if [ ! -x "$DEV/bin/luajit" ]; then
    rm -rf LuaJIT
    git clone --depth 1 --branch "$LUAJIT_REF" https://github.com/LuaJIT/LuaJIT.git
    make -C LuaJIT PREFIX="$DEV" -j"$(nproc)"
    make -C LuaJIT install PREFIX="$DEV"
    ln -sf "$(ls "$DEV"/bin/luajit-2.1* | head -1)" "$DEV/bin/luajit"
fi

# LuaRocks itself runs on PUC Lua 5.1: LuaJIT cannot load the luarocks.org manifest
# ("main function has more than 65536 constants"). The installed rocks are Lua 5.1
# rocks and run fine under LuaJIT, which is what spec/run.sh uses.
if [ ! -x "$DEV/lua51/bin/lua" ]; then
    rm -rf lua-5.1.5
    curl -fsSL https://www.lua.org/ftp/lua-5.1.5.tar.gz | tar xz
    # No readline: plain POSIX build with dlopen so C rocks can be loaded.
    make -C lua-5.1.5/src all MYCFLAGS="-DLUA_USE_POSIX -DLUA_USE_DLOPEN" MYLIBS="-Wl,-E -ldl"
    make -C lua-5.1.5 install INSTALL_TOP="$DEV/lua51"
fi

if [ ! -x "$DEV/bin/luarocks" ] || ! grep -q lua51 "$DEV/etc/luarocks/config-5.1.lua" 2>/dev/null; then
    rm -rf "luarocks-$LUAROCKS_VERSION"
    curl -fsSL "https://luarocks.github.io/luarocks/releases/luarocks-$LUAROCKS_VERSION.tar.gz" | tar xz
    cd "luarocks-$LUAROCKS_VERSION"
    ./configure --prefix="$DEV" --with-lua="$DEV/lua51"
    make && make install
    cd ..
fi

if [ ! -x "$DEV/bin/busted" ]; then
    "$DEV/bin/luarocks" install busted
fi

if [ ! -f "$DEV/lua/lua-ljsqlite3/init.lua" ]; then
    mkdir -p "$DEV/lua/lua-ljsqlite3"
    curl -fsSL -o "$DEV/lua/lua-ljsqlite3/init.lua" \
        "https://raw.githubusercontent.com/koreader/koreader-base/$KOBASE_SHA/thirdparty/lua-ljsqlite3/init.lua"
fi

echo "spec environment ready in $DEV"
