#!/bin/bash

: ${CC=gcc}
: ${CFLAGS=-O3 -s}
: ${BIN=server}
[[ "$@" == "clean" ]] && rm -rf packed.c lua $BIN && exit 0
[[ ! -e "packed.c" && ! -e "lua" ]] && $CC lib/lua/onelua.c -o lua -lm
[[ ! -e "packed.c" ]] && ./lua lib/wtk/scripts/pack.lua *.lua wtk/*.lua > src/packed.c
$CC -DMAKE_LIB=1 `pkg-config sqlite3 --cflags` -Ilib/lua lib/lua/onelua.c src/*.c -o $BIN `pkg-config sqlite3 --libs --static`-lm  $@
