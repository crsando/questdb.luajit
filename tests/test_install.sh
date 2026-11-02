#!/bin/sh
# Stage, relocate and load installed packages, never touching system files.
set -eu
root=$1
luajit=$(command -v "$2")
library=$3
work=$(mktemp -d "$root/build/install-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
for mode in default custom override; do
  stage="$work/$mode-stage"
  prefix=/usr/local
  module=/usr/local/share/lua/5.1/questdb
  libdir=/usr/local/lib/questdb-luajit
  if [ "$mode" = custom ]; then
    prefix='/opt/questdb client'
    module="$prefix/share/lua/5.1/questdb"
    libdir="$prefix/lib/questdb-luajit"
  elif [ "$mode" = override ]; then
    prefix=/opt/questdb
    module=/opt/lua/modules/questdb
    libdir=/opt/private/libs/questdb-luajit
  fi
  make -s -C "$root" install PREFIX="$prefix" LUA_MODULE_DIR="$module" \
    PRIVATE_LIBDIR="$libdir" DESTDIR="$stage"
  ! grep -F "$stage" "$stage$module/_install.lua"
  cmp "$root/build/lib/$library" "$stage$libdir/$library"
  cmp "$root/build/distribution/LICENSE" "$stage$libdir/LICENSE"
  mv "$stage" "$work/$mode-relocated"
  stage="$work/$mode-relocated"
  (
    cd /
    unset QUESTDB_CLIENT_LIB QUESTDB_CLIENT_LIBRARY
    LUA_PATH="$stage${module%/questdb}/?.lua;$stage${module%/questdb}/?/init.lua" \
      EXPECT_MODULE="$stage$module" "$luajit" "$root/tests/test_installed.lua"
    # Run meaningful timestamp/lifecycle regressions using installed modules.
    LUA_PATH="$stage${module%/questdb}/?.lua;$stage${module%/questdb}/?/init.lua" \
      "$luajit" "$root/tests/test_time.lua"
    LUA_PATH="$stage${module%/questdb}/?.lua;$stage${module%/questdb}/?/init.lua" \
      "$luajit" "$root/tests/test_row.lua"
  )
  mv "$stage$libdir/$library" "$stage$libdir/$library.saved"
  (
    cd /
    unset QUESTDB_CLIENT_LIB QUESTDB_CLIENT_LIBRARY
    export LUA_PATH="$stage${module%/questdb}/?.lua;$stage${module%/questdb}/?/init.lua"
    "$luajit" -e 'local n=require "questdb.native"; assert(not pcall(n.load), "missing private library must not fall back")'
    QUESTDB_CLIENT_LIB="$root/build/lib/$library" "$luajit" -e 'local n=require "questdb.native"; assert(n.load()); assert(n.loaded_from(n.load()) == os.getenv("QUESTDB_CLIENT_LIB"))'
  )
  mv "$stage$libdir/$library.saved" "$stage$libdir/$library"
  echo "installed package passed ($mode)"
done
